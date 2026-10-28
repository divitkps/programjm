-- =====================================================================
-- Distributor Group System — Operational Core (PostgreSQL 16)
-- Version 0.1 · 2026-10-24
--
-- Covers the P1 MVP plus the P2 WhatsApp hand-off log:
--   entities & users · products & SKU lifecycle · price list ·
--   distributor & support discounts · store discount matrix ·
--   stores · orders with margin guard · approval chain with context ·
--   stock · targets · commission plan · WhatsApp conversations/hand-offs
--
-- Accounting is parked (decided later). Tax fields that every sale
-- needs anyway (store NPWP, DPP, PPN per line) are kept here so past
-- orders never need rewriting.
--
-- All rules that change over time are rows with a validity range.
-- Overlapping validity for the same key is rejected by the database.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA IF NOT EXISTS core;
SET search_path = core, public;

-- ---------------------------------------------------------------------
-- 1. ENTITIES, TERRITORIES, PEOPLE
-- ---------------------------------------------------------------------

CREATE TABLE entity (
    entity_id        SMALLSERIAL PRIMARY KEY,
    code             VARCHAR(10)  NOT NULL UNIQUE,
    legal_name       VARCHAR(150) NOT NULL,
    entity_role      VARCHAR(12)  NOT NULL CHECK (entity_role IN ('PRINCIPAL','DISTRIBUTOR')),
    npwp             VARCHAR(16),
    region           VARCHAR(60),
    margin_floor_pct NUMERIC(5,2),             -- distributor margin after cost and commission; NULL for principal
    active           BOOLEAN NOT NULL DEFAULT TRUE,
    CHECK (entity_role = 'PRINCIPAL' OR margin_floor_pct IS NOT NULL)
);

CREATE TABLE territory (
    territory_id     SERIAL PRIMARY KEY,
    entity_id        SMALLINT NOT NULL REFERENCES entity,
    code             VARCHAR(20) NOT NULL UNIQUE,   -- unique across the group = exclusive territories
    name             VARCHAR(100) NOT NULL
);

CREATE TABLE app_user (
    user_id          SERIAL PRIMARY KEY,
    entity_id        SMALLINT NOT NULL REFERENCES entity,
    full_name        VARCHAR(100) NOT NULL,
    role             VARCHAR(16) NOT NULL CHECK (role IN
                       ('OWNER','PRN_FINANCE','PRN_SALES_DIR','PRN_PRICING',
                        'DST_HEAD','DST_ADMIN','SALES_REP','WAREHOUSE','HR')),
    reports_to       INT REFERENCES app_user,
    whatsapp_no      VARCHAR(20),
    active           BOOLEAN NOT NULL DEFAULT TRUE
);

-- ---------------------------------------------------------------------
-- 2. PRODUCTS AND PRICING (group masters)
-- ---------------------------------------------------------------------

CREATE TABLE product (
    sku              VARCHAR(40) PRIMARY KEY,
    name             VARCHAR(150) NOT NULL,
    design_code      VARCHAR(40),                   -- design family; many SKUs per design
    collection       VARCHAR(60),
    category         VARCHAR(40) NOT NULL,
    material         VARCHAR(40),                   -- particle board, MDF, solid wood, iron pipe ...
    uom              VARCHAR(10) NOT NULL DEFAULT 'PCS',
    status           VARCHAR(12) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN
                       ('ACTIVE','SLOW','CLEARANCE','DISCONTINUED')),
    launched_on      DATE,
    discontinued_on  DATE,
    replaced_by_sku  VARCHAR(40) REFERENCES product,  -- what the AI/rep offers instead
    image_url        VARCHAR(300)
);

CREATE TABLE price_list (
    sku              VARCHAR(40) NOT NULL REFERENCES product,
    list_price       NUMERIC(18,2) NOT NULL CHECK (list_price > 0),
    valid            DATERANGE NOT NULL,
    set_by           INT REFERENCES app_user,
    EXCLUDE USING gist (sku WITH =, valid WITH &&)
);

CREATE TABLE distributor_discount (             -- principal -> distributor base tier
    entity_id        SMALLINT NOT NULL REFERENCES entity,
    disc_pct         NUMERIC(5,2) NOT NULL CHECK (disc_pct BETWEEN 0 AND 100),
    valid            DATERANGE NOT NULL,
    EXCLUDE USING gist (entity_id WITH =, valid WITH &&)
);

CREATE TABLE support_discount (                 -- extra support / promo from the principal
    support_id       SERIAL PRIMARY KEY,
    entity_id        SMALLINT NOT NULL REFERENCES entity,
    sku              VARCHAR(40) REFERENCES product,      -- one of sku / category / order
    category         VARCHAR(40),
    order_id         BIGINT,                               -- deal-specific support (set after order exists)
    disc_pct         NUMERIC(5,2) NOT NULL CHECK (disc_pct BETWEEN 0 AND 100),
    kind             VARCHAR(10) NOT NULL CHECK (kind IN ('SUPPORT','PROMO','CLEARANCE')),
    reason           VARCHAR(255) NOT NULL,                -- mandatory: transfer-pricing evidence
    valid            DATERANGE NOT NULL,
    approved_by      INT NOT NULL REFERENCES app_user,
    approved_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (num_nonnulls(sku, category, order_id) = 1)
);

CREATE TABLE discount_rule (                    -- the store discount matrix (versioned)
    rule_id          SERIAL PRIMARY KEY,
    customer_class   VARCHAR(6)  NOT NULL CHECK (customer_class IN ('SMALL','BIG')),
    order_type       VARCHAR(8)  NOT NULL CHECK (order_type IN ('REGULAR','PROJECT')),
    min_qty          INT NOT NULL DEFAULT 1,      -- quantity band = total pieces on the order (VERIFY)
    max_disc_pct     NUMERIC(5,2) NOT NULL,
    valid            DATERANGE NOT NULL,
    set_by           INT REFERENCES app_user,
    note             VARCHAR(200),
    EXCLUDE USING gist (customer_class WITH =, order_type WITH =, min_qty WITH =, valid WITH &&)
);

CREATE TABLE commission_plan (
    entity_id        SMALLINT NOT NULL REFERENCES entity,
    basis            VARCHAR(8) NOT NULL CHECK (basis IN ('REVENUE','MARGIN')),
    rate_pct         NUMERIC(5,2) NOT NULL,
    valid            DATERANGE NOT NULL,
    EXCLUDE USING gist (entity_id WITH =, valid WITH &&)
);

-- ---------------------------------------------------------------------
-- 3. STORES (customers) — private to their distributor
-- ---------------------------------------------------------------------

CREATE TABLE customer (
    customer_id      BIGSERIAL PRIMARY KEY,
    entity_id        SMALLINT NOT NULL REFERENCES entity,
    territory_id     INT NOT NULL REFERENCES territory,
    rep_id           INT REFERENCES app_user,
    store_name       VARCHAR(150) NOT NULL,
    owner_name       VARCHAR(100),
    customer_class   VARCHAR(6) NOT NULL DEFAULT 'SMALL' CHECK (customer_class IN ('SMALL','BIG')),
    whatsapp_no      VARCHAR(20),
    wa_opt_in_at     TIMESTAMPTZ,                    -- consent (PDP Law); AI may only message when set
    npwp             VARCHAR(16),                    -- tax identity kept now; accounting comes later
    is_pkp           BOOLEAN NOT NULL DEFAULT FALSE,
    address          VARCHAR(255),
    city             VARCHAR(60),
    credit_limit     NUMERIC(18,2),
    payment_days     SMALLINT NOT NULL DEFAULT 30,
    active           BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE (entity_id, whatsapp_no)
);

-- A store's territory must belong to the same distributor.
CREATE OR REPLACE FUNCTION check_customer_territory() RETURNS trigger AS $$
BEGIN
    IF (SELECT entity_id FROM territory WHERE territory_id = NEW.territory_id) <> NEW.entity_id THEN
        RAISE EXCEPTION 'Store % is in another distributor''s territory', NEW.store_name;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_customer_territory BEFORE INSERT OR UPDATE ON customer
    FOR EACH ROW EXECUTE FUNCTION check_customer_territory();

-- ---------------------------------------------------------------------
-- 4. STOCK
-- ---------------------------------------------------------------------

CREATE TABLE warehouse (
    warehouse_id     SERIAL PRIMARY KEY,
    entity_id        SMALLINT NOT NULL REFERENCES entity,
    name             VARCHAR(80) NOT NULL
);

CREATE TABLE stock (
    warehouse_id     INT NOT NULL REFERENCES warehouse,
    sku              VARCHAR(40) NOT NULL REFERENCES product,
    on_hand          NUMERIC(14,3) NOT NULL DEFAULT 0 CHECK (on_hand >= 0),
    reserved         NUMERIC(14,3) NOT NULL DEFAULT 0 CHECK (reserved >= 0),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (warehouse_id, sku),
    CHECK (reserved <= on_hand)
);

CREATE TABLE stock_movement (
    movement_id      BIGSERIAL PRIMARY KEY,
    warehouse_id     INT NOT NULL REFERENCES warehouse,
    sku              VARCHAR(40) NOT NULL REFERENCES product,
    qty              NUMERIC(14,3) NOT NULL,          -- + in, - out
    movement_type    VARCHAR(12) NOT NULL CHECK (movement_type IN
                       ('RECEIPT','SALE','RETURN','ADJUSTMENT','TRANSFER_IN','TRANSFER_OUT','OPENING')),
    ref_type         VARCHAR(20),
    ref_id           BIGINT,
    moved_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    moved_by         INT REFERENCES app_user
);

-- ---------------------------------------------------------------------
-- 5. ORDERS, MARGIN GUARD, APPROVALS
-- ---------------------------------------------------------------------

CREATE TABLE sales_order (
    order_id         BIGSERIAL PRIMARY KEY,
    entity_id        SMALLINT NOT NULL REFERENCES entity,
    order_no         VARCHAR(30) NOT NULL,
    customer_id      BIGINT NOT NULL REFERENCES customer,
    rep_id           INT REFERENCES app_user,
    order_date       DATE NOT NULL DEFAULT CURRENT_DATE,
    order_type       VARCHAR(8) NOT NULL DEFAULT 'REGULAR' CHECK (order_type IN ('REGULAR','PROJECT')),
    channel          VARCHAR(12) NOT NULL DEFAULT 'REP' CHECK (channel IN ('REP','WHATSAPP_AI','PHONE','VISIT')),
    status           VARCHAR(16) NOT NULL DEFAULT 'DRAFT' CHECK (status IN
                       ('DRAFT','PENDING_APPROVAL','APPROVED','REJECTED','CONFIRMED','DELIVERED','CANCELLED')),
    required_level   VARCHAR(10) CHECK (required_level IN ('REP','MANAGER','PRINCIPAL')),
    total_qty        NUMERIC(14,3),
    total_net        NUMERIC(18,2),
    total_margin     NUMERIC(18,2),
    margin_pct       NUMERIC(7,2),
    priced_at        TIMESTAMPTZ,
    UNIQUE (entity_id, order_no)
);

ALTER TABLE support_discount ADD FOREIGN KEY (order_id) REFERENCES sales_order;

CREATE TABLE sales_order_line (
    line_id            BIGSERIAL PRIMARY KEY,
    order_id           BIGINT NOT NULL REFERENCES sales_order ON DELETE CASCADE,
    sku                VARCHAR(40) NOT NULL REFERENCES product,
    qty                NUMERIC(14,3) NOT NULL CHECK (qty > 0),
    requested_disc_pct NUMERIC(5,2) NOT NULL DEFAULT 0,
    -- filled by price_order(): a frozen snapshot of the rules used
    list_price         NUMERIC(18,2),
    matrix_max_pct     NUMERIC(5,2),
    net_amount         NUMERIC(18,2),
    landed_cost        NUMERIC(18,2),      -- what the distributor paid the principal
    commission         NUMERIC(18,2),
    margin             NUMERIC(18,2),
    margin_pct         NUMERIC(7,2),
    tax_dpp            NUMERIC(18,2),      -- kept for later invoicing; computed when invoicing rules are set
    tax_ppn            NUMERIC(18,2)
);

CREATE TABLE approval_request (
    request_id       BIGSERIAL PRIMARY KEY,
    order_id         BIGINT NOT NULL REFERENCES sales_order,
    level            VARCHAR(10) NOT NULL CHECK (level IN ('MANAGER','PRINCIPAL')),
    reason_code      VARCHAR(20) NOT NULL CHECK (reason_code IN ('ABOVE_MATRIX','BELOW_FLOOR','SUPPORT_NEEDED','PASSED_UP')),
    requested_by     INT REFERENCES app_user,
    context          JSONB NOT NULL,      -- what the approver saw: margin, history, stock, target
    status           VARCHAR(10) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','APPROVED','REJECTED','PASSED_UP','EXPIRED')),
    decided_by       INT REFERENCES app_user,
    decision_note    VARCHAR(500),
    approved_disc_pct NUMERIC(5,2),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_at       TIMESTAMPTZ,
    CHECK (status = 'OPEN' OR (decided_by IS NOT NULL AND decided_at IS NOT NULL)),
    CHECK (status NOT IN ('APPROVED','REJECTED') OR decision_note IS NOT NULL)  -- a reason is always logged
);

-- Prices an order, freezes the rules used on each line, decides who must approve,
-- and opens the approval request with the context the approver needs.
CREATE OR REPLACE FUNCTION price_order(p_order_id BIGINT) RETURNS VARCHAR AS $$
DECLARE
    o            sales_order%ROWTYPE;
    c            customer%ROWTYPE;
    floor_pct    NUMERIC;
    dist_pct     NUMERIC;
    comm_basis   VARCHAR;
    comm_rate    NUMERIC;
    qty_total    NUMERIC;
    level        VARCHAR := 'REP';
    reason       VARCHAR;
    ctx          JSONB;
BEGIN
    SELECT * INTO o FROM sales_order WHERE order_id = p_order_id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM approval_request WHERE order_id = p_order_id AND status = 'OPEN') THEN
        RAISE EXCEPTION 'Order % already waits for approval; decide or withdraw that request first', o.order_no;
    END IF;
    SELECT * INTO c FROM customer WHERE customer_id = o.customer_id;
    SELECT margin_floor_pct INTO floor_pct FROM entity WHERE entity_id = o.entity_id;

    SELECT disc_pct INTO dist_pct FROM distributor_discount
     WHERE entity_id = o.entity_id AND valid @> o.order_date;
    IF dist_pct IS NULL THEN RAISE EXCEPTION 'No distributor discount valid on %', o.order_date; END IF;

    SELECT basis, rate_pct INTO comm_basis, comm_rate FROM commission_plan
     WHERE entity_id = o.entity_id AND valid @> o.order_date;
    IF comm_rate IS NULL THEN RAISE EXCEPTION 'No commission plan valid on %', o.order_date; END IF;

    SELECT SUM(qty) INTO qty_total FROM sales_order_line WHERE order_id = p_order_id;

    -- price every line from the rules valid on the order date
    UPDATE sales_order_line l SET
        list_price     = pl.list_price,
        matrix_max_pct = (SELECT max_disc_pct FROM discount_rule r
                           WHERE r.customer_class = c.customer_class AND r.order_type = o.order_type
                             AND r.min_qty <= qty_total AND r.valid @> o.order_date
                           ORDER BY r.min_qty DESC LIMIT 1),
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
        total_qty    = qty_total,
        total_net    = t.net, total_margin = t.mar,
        margin_pct   = CASE WHEN t.net > 0 THEN round(t.mar / t.net * 100, 2) END,
        priced_at    = now()
      FROM (SELECT SUM(net_amount) net, SUM(margin) mar FROM sales_order_line WHERE order_id = p_order_id) t
     WHERE order_id = p_order_id;
    SELECT * INTO o FROM sales_order WHERE order_id = p_order_id;

    -- who decides
    IF o.margin_pct < floor_pct THEN
        level := 'PRINCIPAL'; reason := 'BELOW_FLOOR';
    ELSIF EXISTS (SELECT 1 FROM sales_order_line WHERE order_id = p_order_id
                   AND (matrix_max_pct IS NULL OR requested_disc_pct > matrix_max_pct)) THEN
        level := 'MANAGER'; reason := 'ABOVE_MATRIX';
    END IF;

    UPDATE sales_order SET required_level = level,
           status = CASE WHEN level = 'REP' THEN 'APPROVED' ELSE 'PENDING_APPROVAL' END
     WHERE order_id = p_order_id;

    IF level <> 'REP' THEN
        ctx := jsonb_build_object(
            'order_margin_pct', o.margin_pct,
            'margin_floor_pct', floor_pct,
            'order_net', o.total_net,
            'lines', (SELECT jsonb_agg(jsonb_build_object(
                         'sku', sku, 'qty', qty, 'requested_disc_pct', requested_disc_pct,
                         'matrix_max_pct', matrix_max_pct, 'margin_pct', margin_pct,
                         'available_stock', (SELECT COALESCE(SUM(s.on_hand - s.reserved),0)
                                               FROM stock s JOIN warehouse w USING (warehouse_id)
                                              WHERE w.entity_id = o.entity_id AND s.sku = l.sku)))
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
        VALUES (p_order_id, level, reason, o.rep_id, ctx);
    END IF;

    RETURN level;
END $$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- 6. TARGETS
-- ---------------------------------------------------------------------

CREATE TABLE sales_target (
    target_id        SERIAL PRIMARY KEY,
    entity_id        SMALLINT NOT NULL REFERENCES entity,
    rep_id           INT REFERENCES app_user,          -- NULL = whole distributor
    period           DATE NOT NULL,                    -- first day of month
    revenue_target   NUMERIC(18,2) NOT NULL,
    margin_target    NUMERIC(18,2),
    focus_category   VARCHAR(40),
    UNIQUE NULLS NOT DISTINCT (entity_id, rep_id, period),
    CHECK (period = date_trunc('month', period)::date)
);

-- ---------------------------------------------------------------------
-- 7. WHATSAPP AI: conversations and hand-offs
-- ---------------------------------------------------------------------

CREATE TABLE conversation (
    conversation_id  BIGSERIAL PRIMARY KEY,
    entity_id        SMALLINT NOT NULL REFERENCES entity,   -- each distributor's AI is isolated
    customer_id      BIGINT NOT NULL REFERENCES customer,
    started_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    mode             VARCHAR(6) NOT NULL DEFAULT 'AI' CHECK (mode IN ('AI','HUMAN','CLOSED')),
    intent_score     NUMERIC(4,2),                         -- 0..1 from the AI
    handoff_reason   VARCHAR(20) CHECK (handoff_reason IN
                       ('DISCOUNT_REQUEST','PROJECT_PRICE','LARGE_QTY','COMPLAINT','PAYMENT','DELIVERY','ASKED_HUMAN')),
    handed_to        INT REFERENCES app_user,
    handed_at        TIMESTAMPTZ,
    first_human_reply_at TIMESTAMPTZ,
    escalated_at     TIMESTAMPTZ,                          -- to manager when rep did not answer in time
    summary          TEXT,                                 -- AI summary given to the rep
    resulting_order_id BIGINT REFERENCES sales_order,
    CHECK (mode <> 'HUMAN' OR (handed_to IS NOT NULL AND handoff_reason IS NOT NULL))
);

CREATE TABLE message (
    message_id       BIGSERIAL PRIMARY KEY,
    conversation_id  BIGINT NOT NULL REFERENCES conversation ON DELETE CASCADE,
    sender           VARCHAR(6) NOT NULL CHECK (sender IN ('STORE','AI','HUMAN')),
    body             TEXT,
    template_name    VARCHAR(60),                          -- set when a paid template was used
    sent_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    wa_message_id    VARCHAR(80) UNIQUE
);

-- The AI may only message stores that opted in.
CREATE OR REPLACE FUNCTION check_ai_consent() RETURNS trigger AS $$
BEGIN
    IF NEW.sender = 'AI' AND (SELECT c.wa_opt_in_at FROM conversation v JOIN customer c USING (customer_id)
                               WHERE v.conversation_id = NEW.conversation_id) IS NULL THEN
        RAISE EXCEPTION 'Store has not opted in to WhatsApp messages';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_ai_consent BEFORE INSERT ON message FOR EACH ROW EXECUTE FUNCTION check_ai_consent();

-- ---------------------------------------------------------------------
-- 7b. RECEIVABLES (operational, not the general ledger)
-- ---------------------------------------------------------------------

CREATE TABLE invoice (
    invoice_id       BIGSERIAL PRIMARY KEY,
    entity_id        SMALLINT NOT NULL REFERENCES entity,
    invoice_no       VARCHAR(30) NOT NULL,
    order_id         BIGINT REFERENCES sales_order,
    customer_id      BIGINT NOT NULL REFERENCES customer,
    invoice_date     DATE NOT NULL,
    due_date         DATE NOT NULL,
    total_amount     NUMERIC(18,2) NOT NULL CHECK (total_amount > 0),
    status           VARCHAR(8) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','PAID','VOID')),
    UNIQUE (entity_id, invoice_no)
);

CREATE TABLE payment_received (
    payment_id       BIGSERIAL PRIMARY KEY,
    invoice_id       BIGINT NOT NULL REFERENCES invoice,
    paid_on          DATE NOT NULL,
    amount           NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    reference        VARCHAR(60)
);

CREATE TABLE payment_promise (                 -- "janji bayar" captured by rep or AI
    promise_id       BIGSERIAL PRIMARY KEY,
    invoice_id       BIGINT NOT NULL REFERENCES invoice,
    promised_on      DATE NOT NULL,
    amount           NUMERIC(18,2) NOT NULL,
    captured_by      VARCHAR(6) NOT NULL CHECK (captured_by IN ('AI','REP','ADMIN')),
    kept             BOOLEAN,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 7c. AI AGENTS: tasks, alerts, runs, scores
-- ---------------------------------------------------------------------

CREATE TABLE follow_up_task (
    task_id          BIGSERIAL PRIMARY KEY,
    entity_id        SMALLINT NOT NULL REFERENCES entity,
    assigned_to      INT NOT NULL REFERENCES app_user,
    customer_id      BIGINT REFERENCES customer,
    task_type        VARCHAR(16) NOT NULL CHECK (task_type IN
                       ('HOT_LEAD','QUOTE_FOLLOWUP','REORDER_CHECK','DORMANT_STORE','COLLECTION','VISIT','APPROVAL','OTHER')),
    source           VARCHAR(20) NOT NULL,         -- which agent or person created it
    source_ref       VARCHAR(60),                  -- conversation / invoice / order id
    title            VARCHAR(200) NOT NULL,
    context          JSONB,
    priority         SMALLINT NOT NULL DEFAULT 2 CHECK (priority BETWEEN 1 AND 3),  -- 1 = today
    due_at           TIMESTAMPTZ NOT NULL,
    status           VARCHAR(10) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','DONE','SNOOZED','CANCELLED','ESCALATED')),
    outcome          VARCHAR(20) CHECK (outcome IN
                       ('ORDER','QUOTE_SENT','NO_NEED_NOW','LOST','PAID','PROMISED','NO_ANSWER','OTHER')),
    outcome_note     VARCHAR(500),
    done_at          TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (status <> 'DONE' OR outcome IS NOT NULL)    -- no task closes without an outcome
);
-- An agent may not open the same task twice.
CREATE UNIQUE INDEX ux_task_open_once ON follow_up_task (task_type, source_ref)
    WHERE status = 'OPEN' AND source_ref IS NOT NULL;

CREATE TABLE ai_alert (
    alert_id         BIGSERIAL PRIMARY KEY,
    entity_id        SMALLINT REFERENCES entity,
    agent            VARCHAR(20) NOT NULL,
    severity         VARCHAR(8) NOT NULL CHECK (severity IN ('INFO','WARN','CRITICAL')),
    subject          VARCHAR(200) NOT NULL,
    detail           JSONB,
    sent_to          INT REFERENCES app_user,
    acknowledged_at  TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE agent_run (                       -- every agent run is logged, success or not
    run_id           BIGSERIAL PRIMARY KEY,
    agent            VARCHAR(20) NOT NULL,
    entity_id        SMALLINT REFERENCES entity,
    started_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at      TIMESTAMPTZ,
    status           VARCHAR(8) NOT NULL DEFAULT 'RUNNING' CHECK (status IN ('RUNNING','OK','PARTIAL','FAILED')),
    items_checked    INT,
    actions_taken    INT,
    error            TEXT
);

CREATE TABLE health_score (
    entity_id        SMALLINT NOT NULL REFERENCES entity,
    week             DATE NOT NULL,
    score            NUMERIC(5,1) NOT NULL,
    components       JSONB NOT NULL,                -- each sub-score and its weight, so the number is explainable
    PRIMARY KEY (entity_id, week)
);

ALTER TABLE conversation ADD COLUMN lead_stage VARCHAR(10) CHECK (lead_stage IN ('COLD','WARM','HOT','CUSTOMER','LOST'));
ALTER TABLE conversation ADD COLUMN outcome VARCHAR(20) CHECK (outcome IN
    ('ORDER','QUOTE_SENT','INFO_ONLY','NO_RESPONSE','LOST','COMPLAINT_RESOLVED','OPTED_OUT'));

-- ---------------------------------------------------------------------
-- 8. VIEWS FOR THE PRINCIPAL AND THE AI
-- ---------------------------------------------------------------------

-- What the AI is allowed to quote: active/slow/clearance SKUs with stock, list price today.
CREATE VIEW v_ai_catalog AS
SELECT w.entity_id, p.sku, p.name, p.category, p.status, pl.list_price,
       SUM(s.on_hand - s.reserved) AS available
  FROM product p
  JOIN price_list pl ON pl.sku = p.sku AND pl.valid @> CURRENT_DATE
  JOIN stock s ON s.sku = p.sku
  JOIN warehouse w USING (warehouse_id)
 WHERE p.status <> 'DISCONTINUED'
 GROUP BY w.entity_id, p.sku, p.name, p.category, p.status, pl.list_price
HAVING SUM(s.on_hand - s.reserved) > 0;

CREATE VIEW v_target_progress AS
SELECT t.entity_id, t.rep_id, t.period, t.revenue_target,
       COALESCE(SUM(o.total_net),0) AS actual_net,
       round(COALESCE(SUM(o.total_net),0) / t.revenue_target * 100, 1) AS progress_pct,
       round(100.0 * (LEAST(CURRENT_DATE, (t.period + INTERVAL '1 month - 1 day')::date) - t.period + 1)
             / EXTRACT(DAY FROM t.period + INTERVAL '1 month - 1 day'), 1) AS month_elapsed_pct
  FROM sales_target t
  LEFT JOIN sales_order o ON o.entity_id = t.entity_id
       AND (t.rep_id IS NULL OR o.rep_id = t.rep_id)
       AND date_trunc('month', o.order_date) = t.period
       AND o.status IN ('APPROVED','CONFIRMED','DELIVERED')
 GROUP BY t.target_id;

-- Discount given vs allowed: the principal's weekly leakage report.
CREATE VIEW v_discount_leakage AS
SELECT o.entity_id, o.rep_id, date_trunc('week', o.order_date)::date AS week,
       COUNT(DISTINCT o.order_id) AS orders,
       SUM(l.net_amount) AS net_sales,
       SUM(l.list_price * l.qty * GREATEST(l.requested_disc_pct - COALESCE(l.matrix_max_pct,0), 0) / 100)
           AS discount_above_matrix,
       COUNT(*) FILTER (WHERE l.requested_disc_pct > COALESCE(l.matrix_max_pct,0)) AS lines_above_matrix,
       COUNT(DISTINCT o.order_id) FILTER (WHERE o.required_level = 'PRINCIPAL') AS orders_below_floor
  FROM sales_order o JOIN sales_order_line l USING (order_id)
 WHERE o.status IN ('APPROVED','CONFIRMED','DELIVERED')
 GROUP BY 1,2,3;

-- Approval speed and load per level: is the principal the bottleneck?
CREATE VIEW v_approval_kpi AS
SELECT o.entity_id, a.level, date_trunc('month', a.created_at)::date AS month,
       COUNT(*) AS requests,
       COUNT(*) FILTER (WHERE a.status = 'PASSED_UP') AS passed_up,
       COUNT(*) FILTER (WHERE a.status = 'OPEN') AS still_open,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM a.decided_at - a.created_at)/3600)
           FILTER (WHERE a.decided_at IS NOT NULL) AS median_hours_to_decide
  FROM approval_request a JOIN sales_order o USING (order_id)
 GROUP BY 1,2,3;

-- Overdue receivables per store (input to the collections agent).
CREATE VIEW v_overdue AS
SELECT i.entity_id, i.customer_id, c.rep_id, i.invoice_id, i.invoice_no, i.due_date,
       i.total_amount - COALESCE(SUM(p.amount),0) AS open_amount,
       CURRENT_DATE - i.due_date AS days_overdue,
       (SELECT MAX(promised_on) FROM payment_promise pp WHERE pp.invoice_id = i.invoice_id) AS last_promise
  FROM invoice i
  JOIN customer c USING (customer_id)
  LEFT JOIN payment_received p USING (invoice_id)
 WHERE i.status = 'OPEN' AND i.due_date < CURRENT_DATE
 GROUP BY i.invoice_id, c.rep_id
HAVING i.total_amount - COALESCE(SUM(p.amount),0) > 0;

-- Stores whose usual reorder gap has passed (input to the outreach agent).
CREATE VIEW v_reorder_due AS
WITH gaps AS (
    SELECT customer_id, order_date,
           order_date - LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date) AS gap
      FROM sales_order WHERE status IN ('CONFIRMED','DELIVERED')
)
SELECT c.entity_id, c.customer_id, c.store_name, c.rep_id,
       MAX(g.order_date) AS last_order,
       round(AVG(g.gap)) AS usual_gap_days,
       CURRENT_DATE - MAX(g.order_date) AS days_since_last
  FROM customer c JOIN gaps g USING (customer_id)
 WHERE c.active
 GROUP BY c.customer_id
HAVING COUNT(g.gap) >= 2                                   -- at least 3 orders to know a rhythm
   AND CURRENT_DATE - MAX(g.order_date) >= round(AVG(g.gap));

-- WhatsApp hand-off performance.
CREATE VIEW v_handoff_kpi AS
SELECT entity_id, date_trunc('month', handed_at)::date AS month,
       COUNT(*) AS handoffs,
       COUNT(resulting_order_id) AS became_orders,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM first_human_reply_at - handed_at)/60)
           AS median_minutes_to_human_reply,
       COUNT(*) FILTER (WHERE escalated_at IS NOT NULL) AS escalated_to_manager
  FROM conversation WHERE handed_at IS NOT NULL
 GROUP BY 1,2;
