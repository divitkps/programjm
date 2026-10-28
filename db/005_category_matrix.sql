-- =====================================================================
-- 005 · Discount matrix by product category (owner's decision, 26 Oct 2026)
--   A matrix row is: category x customer class (small/big) x order type
--   (regular/project) x quantity band -> maximum discount %.
--   The quantity band counts the pieces of THAT category on the order.
--   A row with no category is the fallback for categories without their own rows.
-- Safe to run more than once.
-- =====================================================================
SET search_path = core, public;

ALTER TABLE discount_rule    ADD COLUMN IF NOT EXISTS category VARCHAR(40);
ALTER TABLE sales_order_line ADD COLUMN IF NOT EXISTS band_qty NUMERIC(14,3);

ALTER TABLE discount_rule DROP CONSTRAINT IF EXISTS discount_rule_customer_class_order_type_min_qty_valid_excl;
DO $$ BEGIN
    ALTER TABLE discount_rule ADD CONSTRAINT discount_rule_no_overlap
        EXCLUDE USING gist ((COALESCE(category, '')) WITH =, customer_class WITH =, order_type WITH =,
                            min_qty WITH =, valid WITH &&);
EXCEPTION WHEN duplicate_object OR duplicate_table THEN NULL; END $$;

-- Maximum discount for one line: the category's own rows if it has any for this class and
-- order type on that date, otherwise the fallback rows; highest band the quantity reaches.
CREATE OR REPLACE FUNCTION matrix_max_for(p_category VARCHAR, p_class VARCHAR, p_type VARCHAR,
                                          p_qty NUMERIC, p_on DATE) RETURNS NUMERIC AS $$
    WITH candidates AS (
        SELECT r.*, (r.category IS NOT NULL) AS specific
          FROM discount_rule r
         WHERE r.customer_class = p_class AND r.order_type = p_type AND r.valid @> p_on
           AND (r.category = p_category OR r.category IS NULL)
    ), chosen AS (
        SELECT * FROM candidates
         WHERE specific = (SELECT bool_or(specific) FROM candidates)
    )
    SELECT max_disc_pct FROM chosen WHERE min_qty <= p_qty ORDER BY min_qty DESC LIMIT 1;
$$ LANGUAGE sql STABLE;

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
        band_qty          = cq.cat_qty,
        matrix_max_pct    = matrix_max_for(p.category, c.customer_class, o.order_type, cq.cat_qty, o.order_date),
        floor_pct         = line_floor(l.sku, o.entity_id, o.order_date),
        head_min_price    = (head_limit_for(l.sku, o.order_date)).min_unit_price,
        head_max_disc_pct = (head_limit_for(l.sku, o.order_date)).max_disc_pct,
        net_amount        = round(pl.list_price * l.qty * (1 - l.requested_disc_pct/100), 2),
        landed_cost       = round(pl.list_price * l.qty * (1 - dist_pct/100)
                                  * (1 - COALESCE(sup.disc_pct,0)/100), 2)
      FROM price_list pl
      JOIN product p ON p.sku = pl.sku
      JOIN (SELECT pr.category, SUM(x.qty) AS cat_qty            -- quantity band counted per category
              FROM sales_order_line x JOIN product pr USING (sku)
             WHERE x.order_id = p_order_id GROUP BY pr.category) cq ON cq.category = p.category
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
                         'band_qty', band_qty, 'matrix_max_pct', matrix_max_pct, 'margin_pct', margin_pct, 'floor_pct', floor_pct,
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

DO $$
DECLARE f RECORD;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
              WHERE p.pronamespace = 'core'::regnamespace AND p.prokind = 'f'
    LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = core, public', f.sig);
    END LOOP;
END $$;
