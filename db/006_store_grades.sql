-- =====================================================================
-- 006 · Store grades and chain discounts (owner's decision, 26 Oct 2026)
--
--   Principal -> distributor : national price list less a chain discount, e.g. 50%+3%+5%
--   Distributor -> store     : national price list less the store grade's standard
--                              chain, e.g. 40%+5%, or 40%+5%+3% for certain grades
--   A chain discount applies each step to the price left by the previous step:
--   50%+3%+5% = 0.50 x 0.97 x 0.95 = 46.075% of list (53.925% off), not 58% off.
--
--   Selling at the grade's standard price needs nobody's approval.
--   An extra discount on top of the standard, or a special fixed price below it,
--   is an exception: head decides within the item's head limit, otherwise principal.
--   Item margin floors still apply to every line, standard or not.
--
--   Head limit per item now means: a minimum net unit price (Rp), OR
--   a maximum EXTRA discount on top of the store's standard (%).
--
--   The quantity-band matrix from 005 is no longer used for pricing; its table is kept
--   so old orders stay readable.
-- Safe to run more than once.
-- =====================================================================
SET search_path = core, public;

-- ---------------------------------------------------------------- chain discount maths
-- Fraction of the price that remains after a chain: {40,5} -> 0.57
CREATE OR REPLACE FUNCTION chain_factor(p_steps NUMERIC[]) RETURNS NUMERIC AS $$
DECLARE
    f NUMERIC := 1;
    s NUMERIC;
BEGIN
    IF p_steps IS NULL THEN RETURN 1; END IF;
    FOREACH s IN ARRAY p_steps LOOP
        IF s < 0 OR s >= 100 THEN RAISE EXCEPTION 'Discount step % is not between 0 and 100', s; END IF;
        f := f * (1 - s / 100);
    END LOOP;
    RETURN f;
END $$ LANGUAGE plpgsql IMMUTABLE;

-- How people write it: {40,5,3} -> '40%+5%+3%'
CREATE OR REPLACE FUNCTION chain_label(p_steps NUMERIC[]) RETURNS TEXT AS $$
    SELECT COALESCE(string_agg(trim_scale(s)::text || '%', '+' ORDER BY i), '0%')
      FROM unnest(p_steps) WITH ORDINALITY AS t(s, i);
$$ LANGUAGE sql IMMUTABLE;

-- ---------------------------------------------------------------- distributor buying discount as a chain
ALTER TABLE distributor_discount ADD COLUMN IF NOT EXISTS steps NUMERIC[];
UPDATE distributor_discount SET steps = ARRAY[disc_pct] WHERE steps IS NULL;
-- disc_pct stays as the effective total, kept in step with the chain
CREATE OR REPLACE FUNCTION distributor_discount_sync() RETURNS trigger AS $$
BEGIN
    IF NEW.steps IS NULL THEN NEW.steps := ARRAY[NEW.disc_pct]; END IF;
    NEW.disc_pct := round((1 - chain_factor(NEW.steps)) * 100, 2);
    RETURN NEW;
END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_distributor_discount_sync ON distributor_discount;
CREATE TRIGGER trg_distributor_discount_sync BEFORE INSERT OR UPDATE ON distributor_discount
    FOR EACH ROW EXECUTE FUNCTION distributor_discount_sync();

-- ---------------------------------------------------------------- store grades
CREATE TABLE IF NOT EXISTS store_grade (
    entity_id   SMALLINT NOT NULL REFERENCES entity,
    grade_code  VARCHAR(20) NOT NULL,
    name        VARCHAR(80) NOT NULL,
    PRIMARY KEY (entity_id, grade_code)
);

-- Standard discount per grade; a row with a category overrides the grade's general row for that category.
CREATE TABLE IF NOT EXISTS grade_discount (
    rule_id     SERIAL PRIMARY KEY,
    entity_id   SMALLINT NOT NULL,
    grade_code  VARCHAR(20) NOT NULL,
    category    VARCHAR(40),
    steps       NUMERIC[] NOT NULL CHECK (cardinality(steps) BETWEEN 1 AND 6),
    valid       DATERANGE NOT NULL,
    set_by      INT REFERENCES app_user,
    FOREIGN KEY (entity_id, grade_code) REFERENCES store_grade
);
DO $$ BEGIN
    ALTER TABLE grade_discount ADD CONSTRAINT grade_discount_no_overlap
        EXCLUDE USING gist (entity_id WITH =, grade_code WITH =, (COALESCE(category, '')) WITH =, valid WITH &&);
EXCEPTION WHEN duplicate_object OR duplicate_table THEN NULL; END $$;

ALTER TABLE customer ADD COLUMN IF NOT EXISTS grade_code VARCHAR(20);
DO $$ BEGIN
    ALTER TABLE customer ADD CONSTRAINT customer_grade_fk FOREIGN KEY (entity_id, grade_code) REFERENCES store_grade;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE OR REPLACE FUNCTION grade_steps_for(p_entity SMALLINT, p_grade VARCHAR, p_category VARCHAR, p_on DATE)
RETURNS NUMERIC[] AS $$
    SELECT steps FROM grade_discount
     WHERE entity_id = p_entity AND grade_code = p_grade AND valid @> p_on
       AND (category = p_category OR category IS NULL)
     ORDER BY (category IS NOT NULL) DESC LIMIT 1;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------- order lines
ALTER TABLE sales_order_line ADD COLUMN IF NOT EXISTS std_steps          NUMERIC[];
ALTER TABLE sales_order_line ADD COLUMN IF NOT EXISTS std_unit_price     NUMERIC(18,2);
ALTER TABLE sales_order_line ADD COLUMN IF NOT EXISTS extra_disc_pct     NUMERIC(5,2) NOT NULL DEFAULT 0
    CHECK (extra_disc_pct >= 0 AND extra_disc_pct < 100);
ALTER TABLE sales_order_line ADD COLUMN IF NOT EXISTS special_unit_price NUMERIC(18,2) CHECK (special_unit_price > 0);
ALTER TABLE sales_order_line ADD COLUMN IF NOT EXISTS net_unit_price     NUMERIC(18,2);
ALTER TABLE sales_order_line ADD COLUMN IF NOT EXISTS extra_implied_pct  NUMERIC(7,2);
DO $$ BEGIN
    ALTER TABLE sales_order_line ADD CONSTRAINT line_extra_or_special
        CHECK (special_unit_price IS NULL OR extra_disc_pct = 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
COMMENT ON COLUMN sales_order_line.requested_disc_pct IS 'Total discount off the national price list, computed (was entered by hand before 006)';
COMMENT ON COLUMN sales_order_line.matrix_max_pct     IS 'Total discount of the store''s standard grade price: anything deeper needs approval';
COMMENT ON COLUMN item_head_limit.max_disc_pct        IS 'Maximum EXTRA discount on top of the store''s standard price that the head may approve';

-- ---------------------------------------------------------------- routing
CREATE OR REPLACE FUNCTION route_order(p_order_id BIGINT) RETURNS VARCHAR AS $$
DECLARE
    exceptions  BOOLEAN;
    no_limit    BOOLEAN;
    beyond_head BOOLEAN;
BEGIN
    IF EXISTS (SELECT 1 FROM sales_order_line WHERE order_id = p_order_id
                AND floor_pct IS NOT NULL AND margin_pct < floor_pct) THEN
        RETURN 'PRINCIPAL:BELOW_FLOOR';
    END IF;

    -- exceptions: lines priced below the store's standard grade price
    SELECT bool_or(TRUE),
           bool_or(head_min_price IS NULL AND head_max_disc_pct IS NULL),
           bool_or(NOT ((head_min_price IS NOT NULL AND net_unit_price >= head_min_price)
                     OR (head_max_disc_pct IS NOT NULL AND extra_implied_pct <= head_max_disc_pct)))
      INTO exceptions, no_limit, beyond_head
      FROM sales_order_line
     WHERE order_id = p_order_id AND net_unit_price < std_unit_price;

    IF NOT COALESCE(exceptions, FALSE) THEN RETURN 'REP:'; END IF;
    IF no_limit    THEN RETURN 'PRINCIPAL:NO_HEAD_LIMIT'; END IF;
    IF beyond_head THEN RETURN 'PRINCIPAL:ABOVE_HEAD_LIMIT'; END IF;
    RETURN 'MANAGER:ABOVE_MATRIX';
END $$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------- pricing
CREATE OR REPLACE FUNCTION price_order(p_order_id BIGINT) RETURNS VARCHAR AS $$
DECLARE
    o           sales_order%ROWTYPE;
    c           customer%ROWTYPE;
    buy_steps   NUMERIC[];
    comm_basis  VARCHAR;
    comm_rate   NUMERIC;
    route       VARCHAR;
    level       VARCHAR;
    reason      VARCHAR;
    ctx         JSONB;
BEGIN
    SELECT * INTO o FROM sales_order WHERE order_id = p_order_id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM approval_request WHERE order_id = p_order_id AND status = 'OPEN') THEN
        RAISE EXCEPTION 'Order % already waits for approval; decide or withdraw that request first', o.order_no;
    END IF;
    SELECT * INTO c FROM customer WHERE customer_id = o.customer_id;
    IF c.grade_code IS NULL THEN
        RAISE EXCEPTION 'Store % has no grade yet; set its grade before taking orders', c.store_name;
    END IF;

    SELECT steps INTO buy_steps FROM distributor_discount
     WHERE entity_id = o.entity_id AND valid @> o.order_date;
    IF buy_steps IS NULL THEN RAISE EXCEPTION 'No distributor discount valid on %', o.order_date; END IF;

    SELECT basis, rate_pct INTO comm_basis, comm_rate FROM commission_plan
     WHERE entity_id = o.entity_id AND valid @> o.order_date;
    IF comm_rate IS NULL THEN RAISE EXCEPTION 'No commission plan valid on %', o.order_date; END IF;

    -- standard grade price and the price actually asked
    UPDATE sales_order_line l SET
        list_price        = pl.list_price,
        std_steps         = grade_steps_for(o.entity_id, c.grade_code, p.category, o.order_date),
        floor_pct         = line_floor(l.sku, o.entity_id, o.order_date),
        head_min_price    = (head_limit_for(l.sku, o.order_date)).min_unit_price,
        head_max_disc_pct = (head_limit_for(l.sku, o.order_date)).max_disc_pct,
        landed_cost       = round(pl.list_price * l.qty * chain_factor(buy_steps)
                                  * (1 - COALESCE(sup.disc_pct,0)/100), 2)
      FROM price_list pl
      JOIN product p ON p.sku = pl.sku
      LEFT JOIN LATERAL (
          SELECT MAX(s.disc_pct) AS disc_pct FROM support_discount s
           WHERE s.entity_id = o.entity_id AND s.valid @> o.order_date
             AND (s.order_id = p_order_id OR s.sku = pl.sku OR s.category = p.category)
      ) sup ON TRUE
     WHERE l.order_id = p_order_id AND pl.sku = l.sku AND pl.valid @> o.order_date;

    IF EXISTS (SELECT 1 FROM sales_order_line WHERE order_id = p_order_id AND list_price IS NULL) THEN
        RAISE EXCEPTION 'A SKU on order % has no valid list price', o.order_no;
    END IF;
    IF EXISTS (SELECT 1 FROM sales_order_line WHERE order_id = p_order_id AND std_steps IS NULL) THEN
        RAISE EXCEPTION 'Grade % has no standard discount for an item on order %', c.grade_code, o.order_no;
    END IF;

    UPDATE sales_order_line SET
        std_unit_price = round(list_price * chain_factor(std_steps), 2)
     WHERE order_id = p_order_id;
    UPDATE sales_order_line SET
        net_unit_price = COALESCE(special_unit_price, round(std_unit_price * (1 - extra_disc_pct/100), 2))
     WHERE order_id = p_order_id;
    UPDATE sales_order_line SET
        net_amount         = round(net_unit_price * qty, 2),
        requested_disc_pct = round((1 - net_unit_price / list_price) * 100, 2),
        matrix_max_pct     = round((1 - std_unit_price / list_price) * 100, 2),
        extra_implied_pct  = round((1 - net_unit_price / std_unit_price) * 100, 2)
     WHERE order_id = p_order_id;

    UPDATE sales_order_line SET
        commission = round(CASE comm_basis WHEN 'REVENUE' THEN net_amount
                                           ELSE GREATEST(net_amount - landed_cost, 0) END * comm_rate/100, 2)
     WHERE order_id = p_order_id;
    UPDATE sales_order_line SET
        margin     = net_amount - landed_cost - commission,
        margin_pct = CASE WHEN net_amount > 0
                          THEN round((net_amount - landed_cost - commission) / net_amount * 100, 2) END
     WHERE order_id = p_order_id;

    UPDATE sales_order SET
        total_qty = t.qty, total_net = t.net, total_margin = t.mar,
        margin_pct = CASE WHEN t.net > 0 THEN round(t.mar / t.net * 100, 2) END,
        priced_at = now()
      FROM (SELECT SUM(qty) qty, SUM(net_amount) net, SUM(margin) mar
              FROM sales_order_line WHERE order_id = p_order_id) t
     WHERE order_id = p_order_id;
    SELECT * INTO o FROM sales_order WHERE order_id = p_order_id;

    route  := route_order(p_order_id);
    level  := split_part(route, ':', 1);
    reason := NULLIF(split_part(route, ':', 2), '');

    UPDATE sales_order SET required_level = level,
           status      = CASE WHEN level = 'REP' THEN 'APPROVED' ELSE 'PENDING_APPROVAL' END,
           approved_at = CASE WHEN level = 'REP' THEN now() END
     WHERE order_id = p_order_id;

    IF level <> 'REP' THEN
        ctx := jsonb_build_object(
            'store_grade', c.grade_code,
            'order_margin_pct', o.margin_pct,
            'order_net', o.total_net,
            'lines', (SELECT jsonb_agg(jsonb_build_object(
                         'sku', sku, 'qty', qty,
                         'standard', chain_label(std_steps), 'std_unit_price', std_unit_price,
                         'extra_disc_pct', extra_disc_pct, 'special_unit_price', special_unit_price,
                         'net_unit_price', net_unit_price, 'extra_implied_pct', extra_implied_pct,
                         'total_disc_pct', requested_disc_pct,
                         'margin_pct', margin_pct, 'floor_pct', floor_pct,
                         'head_min_price', head_min_price, 'head_max_disc_pct', head_max_disc_pct,
                         'available_stock', (SELECT COALESCE(SUM(s.on_hand - s.reserved),0)
                                               FROM stock s JOIN warehouse w USING (warehouse_id)
                                              WHERE w.entity_id = o.entity_id AND s.sku = l.sku)) ORDER BY line_id)
                        FROM sales_order_line l WHERE order_id = p_order_id),
            'store_6m_net', (SELECT COALESCE(SUM(total_net),0) FROM sales_order
                              WHERE customer_id = o.customer_id AND order_id <> p_order_id
                                AND status IN ('CONFIRMED','DELIVERED')
                                AND order_date >= o.order_date - INTERVAL '6 months'),
            'store_6m_avg_margin_pct', (SELECT round(AVG(margin_pct),2) FROM sales_order
                              WHERE customer_id = o.customer_id AND order_id <> p_order_id
                                AND status IN ('CONFIRMED','DELIVERED')
                                AND order_date >= o.order_date - INTERVAL '6 months'),
            'rep_target_progress_pct', (SELECT progress_pct FROM v_target_progress v
                              WHERE v.rep_id = o.rep_id AND v.period = date_trunc('month', o.order_date)::date));
        INSERT INTO approval_request (order_id, level, reason_code, requested_by, context)
        VALUES (p_order_id, level, reason, COALESCE(o.entered_by, o.rep_id), ctx);
    END IF;
    RETURN level;
END $$ LANGUAGE plpgsql;

-- Stores that cannot take orders yet because they have no grade.
CREATE OR REPLACE VIEW v_stores_without_grade AS
SELECT c.entity_id, c.customer_id, c.store_name, c.city
  FROM customer c WHERE c.active AND c.grade_code IS NULL;

DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              WHERE p.pronamespace = 'core'::regnamespace AND p.prokind = 'f'
    LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = core, public', f.sig);
    END LOOP;
END $$;
