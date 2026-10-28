-- =====================================================================
-- 004 · Distributor-head approval limit per item (owner's decision, 26 Oct 2026)
--   Each item has a head limit, set EITHER as a minimum net price per unit (Rp)
--   OR as a maximum discount (%). Resolution: SKU rule, then category rule.
--   A line above the discount matrix goes to:
--     the distributor head  if it stays within the head's limit for that item;
--     the principal         if it goes beyond it, or the item has no head limit.
--   Replaces the single order-value limit from 003.
--   Approval validity: 7 days.
-- Safe to run more than once.
-- =====================================================================
SET search_path = core, public;

CREATE TABLE IF NOT EXISTS item_head_limit (
    limit_id        SERIAL PRIMARY KEY,
    sku             VARCHAR(40) REFERENCES product,
    category        VARCHAR(40),
    min_unit_price  NUMERIC(18,2) CHECK (min_unit_price > 0),
    max_disc_pct    NUMERIC(5,2)  CHECK (max_disc_pct BETWEEN 0 AND 100),
    valid           DATERANGE NOT NULL,
    set_by          INT REFERENCES app_user,
    note            VARCHAR(200),
    CHECK (num_nonnulls(sku, category) = 1),
    CHECK (num_nonnulls(min_unit_price, max_disc_pct) = 1)     -- rupiah OR percent, never both
);
DO $$ BEGIN
    ALTER TABLE item_head_limit ADD CONSTRAINT item_head_limit_no_overlap
        EXCLUDE USING gist ((COALESCE(sku, '')) WITH =, (COALESCE(category, '')) WITH =, valid WITH &&);
EXCEPTION WHEN duplicate_object OR duplicate_table THEN NULL; END $$;

ALTER TABLE sales_order_line ADD COLUMN IF NOT EXISTS head_min_price    NUMERIC(18,2);
ALTER TABLE sales_order_line ADD COLUMN IF NOT EXISTS head_max_disc_pct NUMERIC(5,2);

ALTER TABLE approval_request DROP CONSTRAINT IF EXISTS approval_request_reason_code_check;
ALTER TABLE approval_request ADD CONSTRAINT approval_request_reason_code_check CHECK (reason_code IN
    ('ABOVE_MATRIX','BELOW_FLOOR','SUPPORT_NEEDED','PASSED_UP','ABOVE_HEAD_LIMIT','NO_HEAD_LIMIT','OWN_ORDER'));

-- The order-value limit is replaced by per-item limits.
DELETE FROM app_setting WHERE key = 'head_approval_limit';
-- Owner's decision: approvals stay valid for one week.
UPDATE app_setting SET value = 7, updated_at = now() WHERE key = 'approval_valid_days' AND value IS NULL;

-- Head limit for one item on a date: SKU rule first, then the item's category rule.
CREATE OR REPLACE FUNCTION head_limit_for(p_sku VARCHAR, p_on DATE,
                                          OUT min_unit_price NUMERIC, OUT max_disc_pct NUMERIC) AS $$
    SELECT h.min_unit_price, h.max_disc_pct
      FROM item_head_limit h
     WHERE h.valid @> p_on
       AND (h.sku = p_sku OR h.category = (SELECT category FROM product WHERE sku = p_sku))
     ORDER BY (h.sku IS NOT NULL) DESC
     LIMIT 1;
$$ LANGUAGE sql STABLE;

-- Who decides an order whose lines are already priced. Returns 'LEVEL:REASON'.
CREATE OR REPLACE FUNCTION route_order(p_order_id BIGINT) RETURNS VARCHAR AS $$
DECLARE
    above_matrix BOOLEAN;
    no_limit     BOOLEAN;
    beyond_head  BOOLEAN;
BEGIN
    IF EXISTS (SELECT 1 FROM sales_order_line WHERE order_id = p_order_id
                AND floor_pct IS NOT NULL AND margin_pct < floor_pct) THEN
        RETURN 'PRINCIPAL:BELOW_FLOOR';
    END IF;

    SELECT bool_or(TRUE),
           bool_or(head_min_price IS NULL AND head_max_disc_pct IS NULL),
           bool_or((head_min_price IS NOT NULL AND net_amount / qty < head_min_price)
                OR (head_max_disc_pct IS NOT NULL AND requested_disc_pct > head_max_disc_pct))
      INTO above_matrix, no_limit, beyond_head
      FROM sales_order_line
     WHERE order_id = p_order_id
       AND (matrix_max_pct IS NULL OR requested_disc_pct > matrix_max_pct);

    IF NOT COALESCE(above_matrix, FALSE) THEN RETURN 'REP:'; END IF;
    IF beyond_head THEN RETURN 'PRINCIPAL:ABOVE_HEAD_LIMIT'; END IF;
    IF no_limit    THEN RETURN 'PRINCIPAL:NO_HEAD_LIMIT'; END IF;
    RETURN 'MANAGER:ABOVE_MATRIX';
END $$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION price_order(p_order_id BIGINT) RETURNS VARCHAR AS $$
DECLARE
    o            sales_order%ROWTYPE;
    c            customer%ROWTYPE;
    dist_pct     NUMERIC;
    comm_basis   VARCHAR;
    comm_rate    NUMERIC;
    qty_total    NUMERIC;
    route        VARCHAR;
    level        VARCHAR;
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
        list_price        = pl.list_price,
        matrix_max_pct    = (SELECT max_disc_pct FROM discount_rule r
                              WHERE r.customer_class = c.customer_class AND r.order_type = o.order_type
                                AND r.min_qty <= qty_total AND r.valid @> o.order_date
                              ORDER BY r.min_qty DESC LIMIT 1),
        floor_pct         = line_floor(l.sku, o.entity_id, o.order_date),
        head_min_price    = (head_limit_for(l.sku, o.order_date)).min_unit_price,
        head_max_disc_pct = (head_limit_for(l.sku, o.order_date)).max_disc_pct,
        net_amount        = round(pl.list_price * l.qty * (1 - l.requested_disc_pct/100), 2),
        landed_cost       = round(pl.list_price * l.qty * (1 - dist_pct/100)
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

    route  := route_order(p_order_id);
    level  := split_part(route, ':', 1);
    reason := NULLIF(split_part(route, ':', 2), '');

    UPDATE sales_order SET required_level = level,
           status      = CASE WHEN level = 'REP' THEN 'APPROVED' ELSE 'PENDING_APPROVAL' END,
           approved_at = CASE WHEN level = 'REP' THEN now() END
     WHERE order_id = p_order_id;

    IF level <> 'REP' THEN
        ctx := jsonb_build_object(
            'order_margin_pct', o.margin_pct,
            'order_net', o.total_net,
            'lines', (SELECT jsonb_agg(jsonb_build_object(
                         'sku', sku, 'qty', qty, 'requested_disc_pct', requested_disc_pct,
                         'net_unit_price', round(net_amount / qty, 2),
                         'matrix_max_pct', matrix_max_pct, 'margin_pct', margin_pct, 'floor_pct', floor_pct,
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

-- Items the head cannot approve at all yet: the owner's to-do list after the data load.
CREATE OR REPLACE VIEW v_items_without_head_limit AS
SELECT p.sku, p.name, p.category, p.status
  FROM product p
 WHERE p.status <> 'DISCONTINUED'
   AND (head_limit_for(p.sku, CURRENT_DATE)).min_unit_price IS NULL
   AND (head_limit_for(p.sku, CURRENT_DATE)).max_disc_pct IS NULL;

DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              WHERE p.pronamespace = 'core'::regnamespace AND p.prokind = 'f'
    LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = core, public', f.sig);
    END LOOP;
END $$;
