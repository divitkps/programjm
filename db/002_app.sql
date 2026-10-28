-- =====================================================================
-- 002 · Application layer: logins and the approval decision rules
-- =====================================================================
SET search_path = core, public;

ALTER TABLE app_user ADD COLUMN IF NOT EXISTS email VARCHAR(120) UNIQUE;
ALTER TABLE app_user ADD COLUMN IF NOT EXISTS password_hash VARCHAR(100);

-- Which roles may decide which approval level.
--   MANAGER level  : the distributor head of that distributor, or any principal decision-maker
--   PRINCIPAL level: owner or principal sales director only
CREATE OR REPLACE FUNCTION can_decide(p_user_id INT, p_request_id BIGINT) RETURNS BOOLEAN AS $$
    SELECT CASE
        WHEN a.level = 'MANAGER'   THEN (u.role = 'DST_HEAD' AND u.entity_id = o.entity_id)
                                        OR u.role IN ('OWNER','PRN_SALES_DIR')
        WHEN a.level = 'PRINCIPAL' THEN u.role IN ('OWNER','PRN_SALES_DIR')
        ELSE FALSE END
      FROM approval_request a
      JOIN sales_order o USING (order_id)
      JOIN app_user u ON u.user_id = p_user_id
     WHERE a.request_id = p_request_id AND u.active;
$$ LANGUAGE sql STABLE;

-- Records a decision. APPROVE / REJECT close the request and set the order status.
-- PASS_UP (manager level only) hands the same request, with its context, to the principal.
CREATE OR REPLACE FUNCTION decide_approval(p_request_id BIGINT, p_user_id INT,
                                           p_decision VARCHAR, p_note VARCHAR) RETURNS VARCHAR AS $$
DECLARE
    a approval_request%ROWTYPE;
BEGIN
    SELECT * INTO a FROM approval_request WHERE request_id = p_request_id FOR UPDATE;
    IF a.request_id IS NULL THEN RAISE EXCEPTION 'Approval request % not found', p_request_id; END IF;
    IF a.status <> 'OPEN' THEN RAISE EXCEPTION 'This request was already decided'; END IF;
    IF NOT can_decide(p_user_id, p_request_id) THEN
        RAISE EXCEPTION 'You are not allowed to decide this request';
    END IF;
    IF coalesce(trim(p_note), '') = '' THEN RAISE EXCEPTION 'A short reason is required'; END IF;

    IF p_decision = 'APPROVE' THEN
        UPDATE approval_request SET status = 'APPROVED', decided_by = p_user_id, decided_at = now(),
               decision_note = p_note WHERE request_id = p_request_id;
        UPDATE sales_order SET status = 'APPROVED' WHERE order_id = a.order_id;
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

-- The store confirms an approved order; stock is reserved at that moment.
CREATE OR REPLACE FUNCTION confirm_order(p_order_id BIGINT) RETURNS VOID AS $$
DECLARE
    o sales_order%ROWTYPE;
    l RECORD;
    wh INT;
BEGIN
    SELECT * INTO o FROM sales_order WHERE order_id = p_order_id FOR UPDATE;
    IF o.status <> 'APPROVED' THEN RAISE EXCEPTION 'Only approved orders can be confirmed'; END IF;
    FOR l IN SELECT sku, qty FROM sales_order_line WHERE order_id = p_order_id LOOP
        SELECT s.warehouse_id INTO wh
          FROM stock s JOIN warehouse w USING (warehouse_id)
         WHERE w.entity_id = o.entity_id AND s.sku = l.sku AND s.on_hand - s.reserved >= l.qty
         ORDER BY s.on_hand - s.reserved DESC LIMIT 1;
        IF wh IS NULL THEN RAISE EXCEPTION 'Not enough stock for % (needed %)', l.sku, l.qty; END IF;
        UPDATE stock SET reserved = reserved + l.qty, updated_at = now()
         WHERE warehouse_id = wh AND sku = l.sku;
    END LOOP;
    UPDATE sales_order SET status = 'CONFIRMED' WHERE order_id = p_order_id;
END $$ LANGUAGE plpgsql;
