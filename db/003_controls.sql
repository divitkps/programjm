-- =====================================================================
-- 003 · Controls found while mapping the process flow (26 Oct 2026)
--   Gap 1  nobody decides an order they entered themselves
--   Gap 2  cancel releases stock; delivery takes it out of the warehouse
--   Gap 3  sales count from Confirmed onward; Approved is pipeline
--   Gap 4  approvals expire after a set number of days, then re-price
--   Rule A margin floor is set per item and checked on every line
--   Rule B one fixed value limit for distributor-head approvals
-- Safe to run more than once.
-- =====================================================================
SET search_path = core, public;

-- ---------------------------------------------------------------- settings
CREATE TABLE IF NOT EXISTS app_setting (
    key         VARCHAR(40) PRIMARY KEY,
    value       NUMERIC,
    description VARCHAR(200) NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO app_setting (key, value, description) VALUES
 ('approval_valid_days', NULL, 'Days an approval stays valid before the order must be re-priced (empty = never expires)'),
 ('head_approval_limit', NULL, 'Highest order net value (Rp) a distributor head may approve; above it the principal decides (empty = no limit)')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION setting(p_key VARCHAR) RETURNS NUMERIC AS $$
    SELECT value FROM app_setting WHERE key = p_key;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------- per-item margin floor (Rule A)
-- Resolution order for a line: SKU rule, then category rule, then the distributor's default floor.
CREATE TABLE IF NOT EXISTS item_margin_floor (
    floor_id   SERIAL PRIMARY KEY,
    sku        VARCHAR(40) REFERENCES product,
    category   VARCHAR(40),
    floor_pct  NUMERIC(5,2) NOT NULL CHECK (floor_pct BETWEEN -100 AND 100),
    valid      DATERANGE NOT NULL,
    set_by     INT REFERENCES app_user,
    note       VARCHAR(200),
    CHECK (num_nonnulls(sku, category) = 1)
);
DO $$ BEGIN
    ALTER TABLE item_margin_floor ADD CONSTRAINT item_floor_no_overlap
        EXCLUDE USING gist ((COALESCE(sku, '')) WITH =, (COALESCE(category, '')) WITH =, valid WITH &&);
EXCEPTION WHEN duplicate_object OR duplicate_table THEN NULL; END $$;

CREATE OR REPLACE FUNCTION line_floor(p_sku VARCHAR, p_entity SMALLINT, p_on DATE) RETURNS NUMERIC AS $$
    SELECT COALESCE(
        (SELECT floor_pct FROM item_margin_floor WHERE sku = p_sku AND valid @> p_on),
        (SELECT f.floor_pct FROM item_margin_floor f JOIN product p ON p.category = f.category
          WHERE p.sku = p_sku AND f.valid @> p_on),
        (SELECT margin_floor_pct FROM entity WHERE entity_id = p_entity));
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------- new columns
ALTER TABLE sales_order      ADD COLUMN IF NOT EXISTS entered_by     INT REFERENCES app_user;
ALTER TABLE sales_order      ADD COLUMN IF NOT EXISTS approved_at    TIMESTAMPTZ;
ALTER TABLE sales_order      ADD COLUMN IF NOT EXISTS confirmed_at   TIMESTAMPTZ;
ALTER TABLE sales_order      ADD COLUMN IF NOT EXISTS delivered_at   TIMESTAMPTZ;
ALTER TABLE sales_order      ADD COLUMN IF NOT EXISTS cancelled_at   TIMESTAMPTZ;
ALTER TABLE sales_order      ADD COLUMN IF NOT EXISTS cancelled_by   INT REFERENCES app_user;
ALTER TABLE sales_order      ADD COLUMN IF NOT EXISTS cancel_reason  VARCHAR(300);
ALTER TABLE sales_order_line ADD COLUMN IF NOT EXISTS floor_pct      NUMERIC(5,2);
ALTER TABLE sales_order_line ADD COLUMN IF NOT EXISTS warehouse_id   INT REFERENCES warehouse;

ALTER TABLE approval_request DROP CONSTRAINT IF EXISTS approval_request_reason_code_check;
ALTER TABLE approval_request ADD CONSTRAINT approval_request_reason_code_check CHECK (reason_code IN
    ('ABOVE_MATRIX','BELOW_FLOOR','SUPPORT_NEEDED','PASSED_UP','ABOVE_HEAD_LIMIT','OWN_ORDER'));
ALTER TABLE approval_request DROP CONSTRAINT IF EXISTS approval_request_status_check;
ALTER TABLE approval_request ADD CONSTRAINT approval_request_status_check CHECK (status IN
    ('OPEN','APPROVED','REJECTED','PASSED_UP','EXPIRED','WITHDRAWN'));

-- An order is "approval expired" when approved longer ago than the setting allows.
CREATE OR REPLACE FUNCTION approval_expired(p_order_id BIGINT) RETURNS BOOLEAN AS $$
    SELECT o.status = 'APPROVED' AND setting('approval_valid_days') IS NOT NULL
           AND o.approved_at < now() - make_interval(days => setting('approval_valid_days')::int)
      FROM sales_order o WHERE o.order_id = p_order_id;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------- pricing and routing
CREATE OR REPLACE FUNCTION price_order(p_order_id BIGINT) RETURNS VARCHAR AS $$
DECLARE
    o            sales_order%ROWTYPE;
    c            customer%ROWTYPE;
    dist_pct     NUMERIC;
    comm_basis   VARCHAR;
    comm_rate    NUMERIC;
    qty_total    NUMERIC;
    head_limit   NUMERIC := setting('head_approval_limit');
    level        VARCHAR := 'REP';
    reason       VARCHAR;
    ctx          JSONB;
BEGIN
    SELECT * INTO o FROM sales_order WHERE order_id = p_order_id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM approval_request WHERE order_id = p_order_id AND status = 'OPEN') THEN
        RAISE EXCEPTION 'Order % already waits for approval; decide or withdraw that request first', o.order_no;
    END IF;
    SELECT * INTO c FROM customer WHERE customer_id = o.customer_id;

    SELECT disc_pct INTO dist_pct FROM distributor_discount
     WHERE entity_id = o.entity_id AND valid @> o.order_date;
    IF dist_pct IS NULL THEN RAISE EXCEPTION 'No distributor discount valid on %', o.order_date; END IF;

    SELECT basis, rate_pct INTO comm_basis, comm_rate FROM commission_plan
     WHERE entity_id = o.entity_id AND valid @> o.order_date;
    IF comm_rate IS NULL THEN RAISE EXCEPTION 'No commission plan valid on %', o.order_date; END IF;

    SELECT SUM(qty) INTO qty_total FROM sales_order_line WHERE order_id = p_order_id;

    UPDATE sales_order_line l SET
        list_price     = pl.list_price,
        matrix_max_pct = (SELECT max_disc_pct FROM discount_rule r
                           WHERE r.customer_class = c.customer_class AND r.order_type = o.order_type
                             AND r.min_qty <= qty_total AND r.valid @> o.order_date
                           ORDER BY r.min_qty DESC LIMIT 1),
        floor_pct      = line_floor(l.sku, o.entity_id, o.order_date),
        net_amount     = round(pl.list_price * l.qty * (1 - l.requested_disc_pct/100), 2),
        landed_cost    = round(pl.list_price * l.qty * (1 - dist_pct/100)
                               * (1 - COALESCE(sup.disc_pct,0)/100), 2)
      FROM price_list pl
      LEFT JOIN LATERAL (
          SELECT MAX(s.disc_pct) AS disc_pct FROM support_discount s
           WHERE s.entity_id = o.entity_id AND s.valid @> o.order_date
             AND (s.order_id = p_order_id OR s.sku = pl.sku
                  OR s.category = (SELECT category FROM product WHERE sku = pl.sku))
      ) sup ON TRUE
     WHERE l.order_id = p_order_id AND pl.sku = l.sku AND pl.valid @> o.order_date;

    IF EXISTS (SELECT 1 FROM sales_order_line WHERE order_id = p_order_id AND list_price IS NULL) THEN
        RAISE EXCEPTION 'A SKU on order % has no valid list price', o.order_no;
    END IF;

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
        total_qty = qty_total, total_net = t.net, total_margin = t.mar,
        margin_pct = CASE WHEN t.net > 0 THEN round(t.mar / t.net * 100, 2) END,
        priced_at = now()
      FROM (SELECT SUM(net_amount) net, SUM(margin) mar FROM sales_order_line WHERE order_id = p_order_id) t
     WHERE order_id = p_order_id;
    SELECT * INTO o FROM sales_order WHERE order_id = p_order_id;

    -- who decides: any line below its own floor -> principal (Rule A)
    IF EXISTS (SELECT 1 FROM sales_order_line WHERE order_id = p_order_id
                AND floor_pct IS NOT NULL AND margin_pct < floor_pct) THEN
        level := 'PRINCIPAL'; reason := 'BELOW_FLOOR';
    ELSIF EXISTS (SELECT 1 FROM sales_order_line WHERE order_id = p_order_id
                   AND (matrix_max_pct IS NULL OR requested_disc_pct > matrix_max_pct)) THEN
        IF head_limit IS NOT NULL AND o.total_net > head_limit THEN   -- Rule B
            level := 'PRINCIPAL'; reason := 'ABOVE_HEAD_LIMIT';
        ELSE
            level := 'MANAGER'; reason := 'ABOVE_MATRIX';
        END IF;
    END IF;

    UPDATE sales_order SET required_level = level,
           status      = CASE WHEN level = 'REP' THEN 'APPROVED' ELSE 'PENDING_APPROVAL' END,
           approved_at = CASE WHEN level = 'REP' THEN now() END
     WHERE order_id = p_order_id;

    IF level <> 'REP' THEN
        ctx := jsonb_build_object(
            'order_margin_pct', o.margin_pct,
            'order_net', o.total_net,
            'head_approval_limit', head_limit,
            'lines', (SELECT jsonb_agg(jsonb_build_object(
                         'sku', sku, 'qty', qty, 'requested_disc_pct', requested_disc_pct,
                         'matrix_max_pct', matrix_max_pct, 'margin_pct', margin_pct, 'floor_pct', floor_pct,
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

-- ---------------------------------------------------------------- who may decide (Gap 1)
CREATE OR REPLACE FUNCTION can_decide(p_user_id INT, p_request_id BIGINT) RETURNS BOOLEAN AS $$
    SELECT CASE
        WHEN p_user_id IN (o.entered_by, o.rep_id) THEN FALSE          -- never your own order
        WHEN a.level = 'MANAGER'   THEN (u.role = 'DST_HEAD' AND u.entity_id = o.entity_id)
                                        OR u.role IN ('OWNER','PRN_SALES_DIR')
        WHEN a.level = 'PRINCIPAL' THEN u.role IN ('OWNER','PRN_SALES_DIR')
        ELSE FALSE END
      FROM approval_request a
      JOIN sales_order o USING (order_id)
      JOIN app_user u ON u.user_id = p_user_id
     WHERE a.request_id = p_request_id AND u.active;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION decide_approval(p_request_id BIGINT, p_user_id INT,
                                           p_decision VARCHAR, p_note VARCHAR) RETURNS VARCHAR AS $$
DECLARE
    a approval_request%ROWTYPE;
    o sales_order%ROWTYPE;
BEGIN
    SELECT * INTO a FROM approval_request WHERE request_id = p_request_id FOR UPDATE;
    IF a.request_id IS NULL THEN RAISE EXCEPTION 'Approval request % not found', p_request_id; END IF;
    IF a.status <> 'OPEN' THEN RAISE EXCEPTION 'This request was already decided'; END IF;
    SELECT * INTO o FROM sales_order WHERE order_id = a.order_id;
    IF p_user_id IN (o.entered_by, o.rep_id) THEN
        RAISE EXCEPTION 'You entered this order, so someone else must decide it';
    END IF;
    IF NOT can_decide(p_user_id, p_request_id) THEN
        RAISE EXCEPTION 'You are not allowed to decide this request';
    END IF;
    IF coalesce(trim(p_note), '') = '' THEN RAISE EXCEPTION 'A short reason is required'; END IF;

    IF p_decision = 'APPROVE' THEN
        UPDATE approval_request SET status = 'APPROVED', decided_by = p_user_id, decided_at = now(),
               decision_note = p_note WHERE request_id = p_request_id;
        UPDATE sales_order SET status = 'APPROVED', approved_at = now() WHERE order_id = a.order_id;
    ELSIF p_decision = 'REJECT' THEN
        UPDATE approval_request SET status = 'REJECTED', decided_by = p_user_id, decided_at = now(),
               decision_note = p_note WHERE request_id = p_request_id;
        UPDATE sales_order SET status = 'REJECTED' WHERE order_id = a.order_id;
    ELSIF p_decision = 'PASS_UP' THEN
        IF a.level <> 'MANAGER' THEN RAISE EXCEPTION 'Only manager-level requests can be passed up'; END IF;
        UPDATE approval_request SET status = 'PASSED_UP', decided_by = p_user_id, decided_at = now(),
               decision_note = p_note WHERE request_id = p_request_id;
        INSERT INTO approval_request (order_id, level, reason_code, requested_by, context)
        VALUES (a.order_id, 'PRINCIPAL', 'PASSED_UP', p_user_id,
                a.context || jsonb_build_object('passed_up_note', p_note));
        UPDATE sales_order SET required_level = 'PRINCIPAL' WHERE order_id = a.order_id;
    ELSE
        RAISE EXCEPTION 'Unknown decision %', p_decision;
    END IF;
    RETURN p_decision;
END $$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------- confirm, deliver, cancel (Gaps 2 and 4)
CREATE OR REPLACE FUNCTION confirm_order(p_order_id BIGINT) RETURNS VOID AS $$
DECLARE
    o  sales_order%ROWTYPE;
    l  RECORD;
    wh INT;
BEGIN
    SELECT * INTO o FROM sales_order WHERE order_id = p_order_id FOR UPDATE;
    IF o.status <> 'APPROVED' THEN RAISE EXCEPTION 'Only approved orders can be confirmed'; END IF;
    IF approval_expired(p_order_id) THEN
        RAISE EXCEPTION 'The approval has expired (older than % days); re-price the order first',
              setting('approval_valid_days')::int;
    END IF;
    FOR l IN SELECT line_id, sku, qty FROM sales_order_line WHERE order_id = p_order_id ORDER BY line_id LOOP
        SELECT s.warehouse_id INTO wh
          FROM stock s JOIN warehouse w USING (warehouse_id)
         WHERE w.entity_id = o.entity_id AND s.sku = l.sku AND s.on_hand - s.reserved >= l.qty
         ORDER BY s.on_hand - s.reserved DESC LIMIT 1
         FOR UPDATE OF s;
        IF wh IS NULL THEN RAISE EXCEPTION 'Not enough stock for % (needed %)', l.sku, l.qty; END IF;
        UPDATE stock SET reserved = reserved + l.qty, updated_at = now() WHERE warehouse_id = wh AND sku = l.sku;
        UPDATE sales_order_line SET warehouse_id = wh WHERE line_id = l.line_id;
    END LOOP;
    UPDATE sales_order SET status = 'CONFIRMED', confirmed_at = now() WHERE order_id = p_order_id;
END $$ LANGUAGE plpgsql;

-- Full delivery of a confirmed order: stock leaves the warehouse and is logged.
CREATE OR REPLACE FUNCTION deliver_order(p_order_id BIGINT, p_user_id INT) RETURNS VOID AS $$
DECLARE
    o sales_order%ROWTYPE;
BEGIN
    SELECT * INTO o FROM sales_order WHERE order_id = p_order_id FOR UPDATE;
    IF o.status <> 'CONFIRMED' THEN RAISE EXCEPTION 'Only confirmed orders can be delivered'; END IF;
    UPDATE stock s SET on_hand = s.on_hand - l.qty, reserved = s.reserved - l.qty, updated_at = now()
      FROM sales_order_line l
     WHERE l.order_id = p_order_id AND s.warehouse_id = l.warehouse_id AND s.sku = l.sku;
    INSERT INTO stock_movement (warehouse_id, sku, qty, movement_type, ref_type, ref_id, moved_by)
    SELECT warehouse_id, sku, -qty, 'SALE', 'SALES_ORDER', p_order_id, p_user_id
      FROM sales_order_line WHERE order_id = p_order_id;
    UPDATE sales_order SET status = 'DELIVERED', delivered_at = now() WHERE order_id = p_order_id;
END $$ LANGUAGE plpgsql;

-- Cancel before delivery: reserved stock goes back, an open approval is withdrawn, the reason is kept.
CREATE OR REPLACE FUNCTION cancel_order(p_order_id BIGINT, p_user_id INT, p_reason VARCHAR) RETURNS VOID AS $$
DECLARE
    o sales_order%ROWTYPE;
BEGIN
    SELECT * INTO o FROM sales_order WHERE order_id = p_order_id FOR UPDATE;
    IF o.status NOT IN ('DRAFT','PENDING_APPROVAL','APPROVED','CONFIRMED') THEN
        RAISE EXCEPTION 'A % order cannot be cancelled', lower(replace(o.status, '_', ' '));
    END IF;
    IF coalesce(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'A cancellation reason is required'; END IF;
    IF o.status = 'CONFIRMED' THEN
        UPDATE stock s SET reserved = s.reserved - l.qty, updated_at = now()
          FROM sales_order_line l
         WHERE l.order_id = p_order_id AND s.warehouse_id = l.warehouse_id AND s.sku = l.sku;
    END IF;
    UPDATE approval_request SET status = 'WITHDRAWN', decided_by = p_user_id, decided_at = now(),
           decision_note = 'Order cancelled: ' || p_reason
     WHERE order_id = p_order_id AND status = 'OPEN';
    UPDATE sales_order SET status = 'CANCELLED', cancelled_at = now(), cancelled_by = p_user_id,
           cancel_reason = p_reason WHERE order_id = p_order_id;
END $$ LANGUAGE plpgsql;

-- Expired approval: price again on today's rules. It may route to approval again.
CREATE OR REPLACE FUNCTION reprice_order(p_order_id BIGINT) RETURNS VARCHAR AS $$
DECLARE
    o sales_order%ROWTYPE;
BEGIN
    SELECT * INTO o FROM sales_order WHERE order_id = p_order_id FOR UPDATE;
    IF NOT approval_expired(p_order_id) THEN
        RAISE EXCEPTION 'Only orders with an expired approval can be re-priced';
    END IF;
    UPDATE sales_order SET order_date = CURRENT_DATE, status = 'DRAFT', approved_at = NULL
     WHERE order_id = p_order_id;
    RETURN price_order(p_order_id);
END $$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------- sales = Confirmed onward (Gap 3)
CREATE OR REPLACE VIEW v_target_progress AS
SELECT t.entity_id, t.rep_id, t.period, t.revenue_target,
       COALESCE(SUM(o.total_net),0) AS actual_net,
       round(COALESCE(SUM(o.total_net),0) / t.revenue_target * 100, 1) AS progress_pct,
       round(100.0 * (LEAST(CURRENT_DATE, (t.period + INTERVAL '1 month - 1 day')::date) - t.period + 1)
             / EXTRACT(DAY FROM t.period + INTERVAL '1 month - 1 day'), 1) AS month_elapsed_pct
  FROM sales_target t
  LEFT JOIN sales_order o ON o.entity_id = t.entity_id
       AND (t.rep_id IS NULL OR o.rep_id = t.rep_id)
       AND date_trunc('month', o.order_date) = t.period
       AND o.status IN ('CONFIRMED','DELIVERED')
 GROUP BY t.target_id;

CREATE OR REPLACE VIEW v_discount_leakage AS
SELECT o.entity_id, o.rep_id, date_trunc('week', o.order_date)::date AS week,
       COUNT(DISTINCT o.order_id) AS orders,
       SUM(l.net_amount) AS net_sales,
       SUM(l.list_price * l.qty * GREATEST(l.requested_disc_pct - COALESCE(l.matrix_max_pct,0), 0) / 100)
           AS discount_above_matrix,
       COUNT(*) FILTER (WHERE l.requested_disc_pct > COALESCE(l.matrix_max_pct,0)) AS lines_above_matrix,
       COUNT(DISTINCT o.order_id) FILTER (WHERE o.required_level = 'PRINCIPAL') AS orders_below_floor
  FROM sales_order o JOIN sales_order_line l USING (order_id)
 WHERE o.status IN ('CONFIRMED','DELIVERED')
 GROUP BY 1,2,3;

-- ---------------------------------------------------------------- upgrade housekeeping
-- Orders approved before this version have no approval time: start their clock at the
-- latest recorded approval, else when they were priced, else now.
UPDATE sales_order o SET approved_at = COALESCE(
        (SELECT MAX(decided_at) FROM approval_request a WHERE a.order_id = o.order_id AND a.status = 'APPROVED'),
        o.priced_at, now())
 WHERE o.status = 'APPROVED' AND o.approved_at IS NULL;

-- Every function in this schema finds its tables wherever it is called from
-- (the web app, a report, a scheduled job, or someone at the database console).
DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              WHERE p.pronamespace = 'core'::regnamespace AND p.prokind = 'f'
    LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = core, public', f.sig);
    END LOOP;
END $$;
