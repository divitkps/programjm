-- =====================================================================
-- Distributor Group System — Accounting Layer (PostgreSQL 16)
-- Version 0.1 · 2026-10-24
--
-- Purpose
--   Accounting-ready data for the principal + 8 owned distributors
--   (separate PTs). Built so the group can EITHER:
--     A) keep its own general ledger here, OR
--     B) push documents/journals into a bought accounting program
--        (Accurate, Jurnal, Odoo, etc.) and/or a PJAP for Coretax,
--   without redesigning the operational tables.
--
-- Indonesian specifics handled
--   * One legal entity per PT, each with its own NPWP, periods and books
--   * Reporting standard: SAK EP (replaced SAK ETAP from 1 Jan 2025)
--   * PPN 12% with DPP nilai lain 11/12 for non-luxury goods
--     (PMK 131/2024, faktur code 04) -> rate and DPP factor are DATA,
--     with valid_from/valid_to, never hard-coded
--   * Faktur pajak keluaran/masukan with Coretax status tracking
--   * PPh withholding (bukti potong) as its own table
--   * Intercompany principal -> distributor, linked for elimination
--   * Rupiah amounts in NUMERIC(18,2); tax amounts rounded per rule
--
-- Rules are marked "VERIFY" where a tax consultant must confirm values.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS acc;
SET search_path = acc, public;

-- ---------------------------------------------------------------------
-- 1. ENTITIES AND PERIODS
-- ---------------------------------------------------------------------

CREATE TABLE entity (
    entity_id       SMALLSERIAL PRIMARY KEY,
    code            VARCHAR(10)  NOT NULL UNIQUE,          -- e.g. PRN, DST01
    legal_name      VARCHAR(150) NOT NULL,                 -- PT name as on NPWP
    entity_role     VARCHAR(12)  NOT NULL CHECK (entity_role IN ('PRINCIPAL','DISTRIBUTOR')),
    npwp            VARCHAR(16)  NOT NULL,                 -- 16-digit NPWP (Coretax era)
    nitku           VARCHAR(22),                           -- branch/place-of-business ID if used
    is_pkp          BOOLEAN      NOT NULL DEFAULT TRUE,    -- registered VAT collector
    region          VARCHAR(60),
    functional_ccy  CHAR(3)      NOT NULL DEFAULT 'IDR',
    reporting_std   VARCHAR(10)  NOT NULL DEFAULT 'SAK_EP',
    active          BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE fiscal_period (
    period_id   SERIAL PRIMARY KEY,
    entity_id   SMALLINT NOT NULL REFERENCES entity,
    year        SMALLINT NOT NULL,
    month       SMALLINT NOT NULL CHECK (month BETWEEN 1 AND 13),  -- 13 = year-end adjustments
    start_date  DATE NOT NULL,
    end_date    DATE NOT NULL,
    status      VARCHAR(8) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','SOFT','LOCKED')),
    locked_by   VARCHAR(60),
    locked_at   TIMESTAMPTZ,
    UNIQUE (entity_id, year, month)
);
-- SOFT = only finance roles may post (month-end); LOCKED = nobody posts.

-- ---------------------------------------------------------------------
-- 2. CHART OF ACCOUNTS
--    One group template; every entity uses the same codes so
--    consolidation is a SUM, not a mapping exercise.
-- ---------------------------------------------------------------------

CREATE TABLE account (
    account_id      SERIAL PRIMARY KEY,
    code            VARCHAR(12)  NOT NULL UNIQUE,          -- e.g. 1-1300
    name_id         VARCHAR(120) NOT NULL,                 -- Bahasa name
    name_en         VARCHAR(120),
    parent_id       INT REFERENCES account,
    account_class   VARCHAR(10)  NOT NULL CHECK (account_class IN
                      ('ASSET','LIABILITY','EQUITY','REVENUE','COGS','EXPENSE','OTHER_INC','OTHER_EXP','TAX_EXP')),
    normal_balance  CHAR(1)      NOT NULL CHECK (normal_balance IN ('D','C')),
    is_postable     BOOLEAN      NOT NULL DEFAULT TRUE,    -- headers are not postable
    is_intercompany BOOLEAN      NOT NULL DEFAULT FALSE,   -- requires partner entity on lines
    is_control      BOOLEAN      NOT NULL DEFAULT FALSE,   -- AR/AP/stock: only posted by sub-ledgers
    sak_ep_line     VARCHAR(60),                           -- statement line under SAK EP
    fiscal_treatment VARCHAR(20) DEFAULT 'DEDUCTIBLE' CHECK (fiscal_treatment IN
                      ('DEDUCTIBLE','NON_DEDUCTIBLE','FINAL_TAX','NOT_APPLICABLE')),  -- for koreksi fiskal
    active          BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ---------------------------------------------------------------------
-- 3. TAX MASTER (rates are data with validity dates)
-- ---------------------------------------------------------------------

CREATE TABLE tax_code (
    tax_code_id     SERIAL PRIMARY KEY,
    code            VARCHAR(20) NOT NULL,
    tax_type        VARCHAR(10) NOT NULL CHECK (tax_type IN ('PPN','PPNBM','PPH21','PPH22','PPH23','PPH4_2','PPH15','PPH26')),
    description     VARCHAR(150) NOT NULL,
    rate            NUMERIC(7,4),                          -- percent, e.g. 12.0000; NULL until confirmed
    dpp_num         SMALLINT NOT NULL DEFAULT 1,           -- DPP factor numerator   (11 for 11/12)
    dpp_den         SMALLINT NOT NULL DEFAULT 1,           -- DPP factor denominator (12 for 11/12)
    faktur_code     CHAR(2),                               -- kode transaksi faktur, e.g. '04'
    output_account  INT REFERENCES account,                -- PPN Keluaran / PPh payable
    input_account   INT REFERENCES account,                -- PPN Masukan / prepaid PPh
    valid_from      DATE NOT NULL,
    valid_to        DATE,
    legal_basis     VARCHAR(120),
    UNIQUE (code, valid_from)
);

-- ---------------------------------------------------------------------
-- 4. PARTIES (tax identity needed on every invoice)
-- ---------------------------------------------------------------------

CREATE TABLE party (
    party_id        SERIAL PRIMARY KEY,
    entity_id       SMALLINT NOT NULL REFERENCES entity,   -- owning entity (stores are per distributor)
    party_type      VARCHAR(10) NOT NULL CHECK (party_type IN ('CUSTOMER','SUPPLIER','EMPLOYEE','INTERCO')),
    name            VARCHAR(150) NOT NULL,
    tax_id_type     VARCHAR(6) CHECK (tax_id_type IN ('NPWP','NIK','PASPOR','OTHER')),
    tax_id          VARCHAR(22),                           -- NPWP 16 digits or NIK
    nitku           VARCHAR(22),
    tax_address     VARCHAR(255),
    is_pkp          BOOLEAN NOT NULL DEFAULT FALSE,
    linked_entity_id SMALLINT REFERENCES entity,           -- set when party IS a group entity (interco)
    ops_customer_id BIGINT,                                -- link to operational store record
    active          BOOLEAN NOT NULL DEFAULT TRUE,
    CHECK (party_type <> 'INTERCO' OR linked_entity_id IS NOT NULL)
);
CREATE INDEX ON party (entity_id, party_type);

-- ---------------------------------------------------------------------
-- 5. SUB-LEDGER DOCUMENTS (what operations produce; source of journals)
-- ---------------------------------------------------------------------

CREATE TABLE ar_invoice (                                   -- sales invoice (to store or to distributor)
    invoice_id      BIGSERIAL PRIMARY KEY,
    entity_id       SMALLINT NOT NULL REFERENCES entity,
    invoice_no      VARCHAR(30) NOT NULL,
    invoice_date    DATE NOT NULL,
    due_date        DATE NOT NULL,
    party_id        INT NOT NULL REFERENCES party,
    sales_order_id  BIGINT,                                 -- link to operational order
    is_intercompany BOOLEAN NOT NULL DEFAULT FALSE,
    gross_amount    NUMERIC(18,2) NOT NULL,                 -- list price x qty
    discount_amount NUMERIC(18,2) NOT NULL DEFAULT 0,       -- all discounts on the invoice
    net_amount      NUMERIC(18,2) NOT NULL,                 -- harga jual (basis before DPP factor)
    dpp_amount      NUMERIC(18,2) NOT NULL,                 -- after DPP factor (e.g. 11/12)
    ppn_amount      NUMERIC(18,2) NOT NULL,
    total_amount    NUMERIC(18,2) NOT NULL,                 -- net + PPN
    status          VARCHAR(10) NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','POSTED','VOID','CREDITED')),
    journal_id      BIGINT,
    UNIQUE (entity_id, invoice_no),
    CHECK (net_amount = gross_amount - discount_amount),
    CHECK (total_amount = net_amount + ppn_amount)
);

CREATE TABLE ar_invoice_line (
    line_id         BIGSERIAL PRIMARY KEY,
    invoice_id      BIGINT NOT NULL REFERENCES ar_invoice ON DELETE CASCADE,
    sku             VARCHAR(40) NOT NULL,
    description     VARCHAR(200) NOT NULL,
    qty             NUMERIC(14,3) NOT NULL,
    uom             VARCHAR(10) NOT NULL DEFAULT 'PCS',
    list_price      NUMERIC(18,2) NOT NULL,
    discount_pct    NUMERIC(7,4) NOT NULL DEFAULT 0,         -- total store discount on the line
    support_disc_pct NUMERIC(7,4) NOT NULL DEFAULT 0,        -- principal support/promo (interco only)
    net_amount      NUMERIC(18,2) NOT NULL,
    tax_code_id     INT NOT NULL REFERENCES tax_code,
    dpp_amount      NUMERIC(18,2) NOT NULL,
    ppn_amount      NUMERIC(18,2) NOT NULL,
    cogs_amount     NUMERIC(18,2),                           -- filled by inventory valuation
    revenue_account INT REFERENCES account
);

CREATE TABLE ap_invoice (                                   -- purchase invoice (incl. from principal)
    bill_id         BIGSERIAL PRIMARY KEY,
    entity_id       SMALLINT NOT NULL REFERENCES entity,
    supplier_ref_no VARCHAR(40) NOT NULL,                    -- supplier's invoice number
    bill_date       DATE NOT NULL,
    due_date        DATE NOT NULL,
    party_id        INT NOT NULL REFERENCES party,
    is_intercompany BOOLEAN NOT NULL DEFAULT FALSE,
    net_amount      NUMERIC(18,2) NOT NULL,
    dpp_amount      NUMERIC(18,2) NOT NULL,
    ppn_amount      NUMERIC(18,2) NOT NULL,
    pph_withheld    NUMERIC(18,2) NOT NULL DEFAULT 0,
    total_amount    NUMERIC(18,2) NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','POSTED','VOID')),
    journal_id      BIGINT,
    UNIQUE (entity_id, party_id, supplier_ref_no)
);

CREATE TABLE payment (                                      -- cash in / cash out
    payment_id      BIGSERIAL PRIMARY KEY,
    entity_id       SMALLINT NOT NULL REFERENCES entity,
    direction       CHAR(3) NOT NULL CHECK (direction IN ('IN','OUT')),
    payment_date    DATE NOT NULL,
    party_id        INT NOT NULL REFERENCES party,
    bank_account_id INT NOT NULL REFERENCES account,
    amount          NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    reference       VARCHAR(60),
    status          VARCHAR(10) NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','POSTED','VOID')),
    journal_id      BIGINT
);

CREATE TABLE payment_allocation (                           -- which invoices a payment settles
    allocation_id   BIGSERIAL PRIMARY KEY,
    payment_id      BIGINT NOT NULL REFERENCES payment ON DELETE CASCADE,
    ar_invoice_id   BIGINT REFERENCES ar_invoice,
    ap_bill_id      BIGINT REFERENCES ap_invoice,
    amount          NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    CHECK ((ar_invoice_id IS NULL) <> (ap_bill_id IS NULL))
);

-- ---------------------------------------------------------------------
-- 6. TAX DOCUMENTS (Coretax)
-- ---------------------------------------------------------------------

CREATE TABLE tax_invoice (                                  -- faktur pajak keluaran & masukan
    tax_invoice_id  BIGSERIAL PRIMARY KEY,
    entity_id       SMALLINT NOT NULL REFERENCES entity,
    direction       VARCHAR(8) NOT NULL CHECK (direction IN ('KELUARAN','MASUKAN')),
    ar_invoice_id   BIGINT REFERENCES ar_invoice,
    ap_bill_id      BIGINT REFERENCES ap_invoice,
    faktur_code     CHAR(2) NOT NULL,                       -- e.g. '04'
    faktur_number   VARCHAR(30),                            -- assigned by Coretax on approval
    faktur_date     DATE NOT NULL,
    tax_period      CHAR(6) NOT NULL,                       -- YYYYMM (masa pajak)
    counterparty_tax_id VARCHAR(22),
    dpp_amount      NUMERIC(18,2) NOT NULL,
    ppn_amount      NUMERIC(18,2) NOT NULL,
    ppnbm_amount    NUMERIC(18,2) NOT NULL DEFAULT 0,
    coretax_status  VARCHAR(12) NOT NULL DEFAULT 'PENDING' CHECK (coretax_status IN
                      ('PENDING','SUBMITTED','APPROVED','REJECTED','CANCELLED','REPLACED','CREDITED')),
    coretax_message VARCHAR(500),                           -- rejection reason from Coretax/PJAP
    replaces_id     BIGINT REFERENCES tax_invoice,          -- faktur pengganti
    credited_in_period CHAR(6),                             -- PPN masukan credited in which masa
    submitted_via   VARCHAR(10) CHECK (submitted_via IN ('PORTAL','XML_UPLOAD','PJAP','H2H')),
    CHECK ((ar_invoice_id IS NULL) <> (ap_bill_id IS NULL))
);
CREATE INDEX ON tax_invoice (entity_id, tax_period, direction);

CREATE TABLE tax_return_note (                              -- nota retur (sales returns)
    retur_id        BIGSERIAL PRIMARY KEY,
    entity_id       SMALLINT NOT NULL REFERENCES entity,
    original_tax_invoice_id BIGINT NOT NULL REFERENCES tax_invoice,
    retur_date      DATE NOT NULL,
    dpp_amount      NUMERIC(18,2) NOT NULL,
    ppn_amount      NUMERIC(18,2) NOT NULL,
    coretax_status  VARCHAR(12) NOT NULL DEFAULT 'PENDING'
);

CREATE TABLE withholding_slip (                             -- bukti potong/pungut PPh (e-Bupot)
    slip_id         BIGSERIAL PRIMARY KEY,
    entity_id       SMALLINT NOT NULL REFERENCES entity,
    role            VARCHAR(10) NOT NULL CHECK (role IN ('WITHHELD','SUFFERED')), -- we withheld / was withheld from us
    tax_code_id     INT NOT NULL REFERENCES tax_code,
    party_id        INT NOT NULL REFERENCES party,
    tax_period      CHAR(6) NOT NULL,
    gross_amount    NUMERIC(18,2) NOT NULL,
    tax_amount      NUMERIC(18,2) NOT NULL,
    slip_number     VARCHAR(30),
    ap_bill_id      BIGINT REFERENCES ap_invoice,
    ar_invoice_id   BIGINT REFERENCES ar_invoice,
    coretax_status  VARCHAR(12) NOT NULL DEFAULT 'PENDING'
);

-- ---------------------------------------------------------------------
-- 7. GENERAL LEDGER
-- ---------------------------------------------------------------------

CREATE TABLE journal (
    journal_id      BIGSERIAL PRIMARY KEY,
    entity_id       SMALLINT NOT NULL REFERENCES entity,
    period_id       INT NOT NULL REFERENCES fiscal_period,
    journal_no      VARCHAR(30) NOT NULL,
    journal_date    DATE NOT NULL,
    journal_type    VARCHAR(12) NOT NULL CHECK (journal_type IN
                      ('SALES','PURCHASE','CASH_IN','CASH_OUT','INVENTORY','PAYROLL','ACCRUAL',
                       'ADJUSTMENT','DEPRECIATION','TAX','ELIMINATION','OPENING','CLOSING')),
    source_doc_type VARCHAR(20),                            -- AR_INVOICE, AP_INVOICE, PAYMENT, ...
    source_doc_id   BIGINT,
    description     VARCHAR(255),
    status          VARCHAR(10) NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','POSTED','REVERSED')),
    reverses_id     BIGINT REFERENCES journal,
    posted_by       VARCHAR(60),
    posted_at       TIMESTAMPTZ,
    UNIQUE (entity_id, journal_no)
);
-- One live (posted) journal per source document and journal type.
CREATE UNIQUE INDEX ux_journal_one_posted_per_doc
    ON journal (source_doc_type, source_doc_id, journal_type)
    WHERE status = 'POSTED' AND source_doc_id IS NOT NULL;

CREATE TABLE journal_line (
    line_id         BIGSERIAL PRIMARY KEY,
    journal_id      BIGINT NOT NULL REFERENCES journal ON DELETE CASCADE,
    line_no         SMALLINT NOT NULL,
    account_id      INT NOT NULL REFERENCES account,
    debit           NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (debit  >= 0),
    credit          NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    -- analysis dimensions (what the principal slices by)
    partner_entity_id SMALLINT REFERENCES entity,           -- REQUIRED on intercompany accounts
    party_id        INT REFERENCES party,
    territory_code  VARCHAR(20),
    sales_rep_id    INT,
    product_category VARCHAR(40),
    tax_code_id     INT REFERENCES tax_code,
    memo            VARCHAR(255),
    CHECK ((debit = 0) <> (credit = 0)),
    UNIQUE (journal_id, line_no)
);
CREATE INDEX ON journal_line (account_id);
CREATE INDEX ON journal_line (partner_entity_id) WHERE partner_entity_id IS NOT NULL;

-- Balanced-journal, open-period and interco-partner checks run when a journal is POSTED.
CREATE OR REPLACE FUNCTION check_journal_on_post() RETURNS trigger AS $$
DECLARE
    d NUMERIC; c NUMERIC; p_status TEXT; missing_partner INT;
BEGIN
    IF NEW.status = 'POSTED' AND (TG_OP = 'INSERT' OR OLD.status <> 'POSTED') THEN
        SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0) INTO d, c
          FROM journal_line WHERE journal_id = NEW.journal_id;
        IF d = 0 OR d <> c THEN
            RAISE EXCEPTION 'Journal % not balanced (D % / C %)', NEW.journal_no, d, c;
        END IF;

        SELECT status INTO p_status FROM fiscal_period WHERE period_id = NEW.period_id;
        IF p_status = 'LOCKED' THEN
            RAISE EXCEPTION 'Period for journal % is locked', NEW.journal_no;
        END IF;

        SELECT COUNT(*) INTO missing_partner
          FROM journal_line l JOIN account a USING (account_id)
         WHERE l.journal_id = NEW.journal_id AND a.is_intercompany AND l.partner_entity_id IS NULL;
        IF missing_partner > 0 THEN
            RAISE EXCEPTION 'Journal % has intercompany lines without partner entity', NEW.journal_no;
        END IF;

        NEW.posted_at := COALESCE(NEW.posted_at, now());
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.status = 'POSTED' AND NEW.status = 'DRAFT' THEN
        RAISE EXCEPTION 'Posted journals cannot be reopened; reverse them instead';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_journal_post BEFORE INSERT OR UPDATE ON journal
    FOR EACH ROW EXECUTE FUNCTION check_journal_on_post();

-- Posted lines are immutable.
CREATE OR REPLACE FUNCTION block_posted_line_change() RETURNS trigger AS $$
BEGIN
    IF (SELECT status FROM journal WHERE journal_id = COALESCE(OLD.journal_id, NEW.journal_id)) = 'POSTED' THEN
        RAISE EXCEPTION 'Lines of a posted journal cannot be changed';
    END IF;
    RETURN COALESCE(NEW, OLD);
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_line_lock BEFORE INSERT OR UPDATE OR DELETE ON journal_line
    FOR EACH ROW EXECUTE FUNCTION block_posted_line_change();

-- ---------------------------------------------------------------------
-- 8. POSTING RULES (document event -> accounts; no accounts in app code)
-- ---------------------------------------------------------------------

CREATE TABLE posting_rule (
    rule_id         SERIAL PRIMARY KEY,
    event           VARCHAR(30) NOT NULL,     -- e.g. AR_INVOICE.REVENUE, AR_INVOICE.PPN, PAYMENT_IN.BANK
    entity_role     VARCHAR(12),              -- NULL = all; or PRINCIPAL / DISTRIBUTOR
    is_intercompany BOOLEAN,                  -- NULL = both
    debit_account   INT REFERENCES account,
    credit_account  INT REFERENCES account,
    valid_from      DATE NOT NULL,
    valid_to        DATE
);

-- ---------------------------------------------------------------------
-- 9. INTERCOMPANY
-- ---------------------------------------------------------------------

CREATE TABLE ic_link (                                      -- principal sale <-> distributor purchase
    ic_id           BIGSERIAL PRIMARY KEY,
    seller_entity_id SMALLINT NOT NULL REFERENCES entity,
    buyer_entity_id  SMALLINT NOT NULL REFERENCES entity,
    ar_invoice_id   BIGINT NOT NULL UNIQUE REFERENCES ar_invoice,
    ap_bill_id      BIGINT UNIQUE REFERENCES ap_invoice,    -- NULL until the buyer books it
    support_discount_ref VARCHAR(40),                       -- link to approved support/promo discount
    matched         BOOLEAN NOT NULL DEFAULT FALSE,
    difference      NUMERIC(18,2) NOT NULL DEFAULT 0,
    CHECK (seller_entity_id <> buyer_entity_id)
);

-- ---------------------------------------------------------------------
-- 10. EXTERNAL ACCOUNTING / TAX INTEGRATION (outbox pattern)
--     Works for: CSV import files, accounting-program APIs,
--     Coretax XML, PJAP APIs. Nothing is sent twice (idempotency key).
-- ---------------------------------------------------------------------

CREATE TABLE ext_system (
    ext_system_id   SMALLSERIAL PRIMARY KEY,
    code            VARCHAR(20) NOT NULL UNIQUE,            -- ACCURATE, JURNAL, ODOO, CSV, CORETAX_XML, PJAP
    kind            VARCHAR(10) NOT NULL CHECK (kind IN ('ACCOUNTING','TAX','FILE')),
    sync_level      VARCHAR(10) NOT NULL CHECK (sync_level IN ('DOCUMENT','JOURNAL','SUMMARY')),
    -- DOCUMENT = invoices/bills/payments with lines (target makes its own journals & faktur)
    -- JOURNAL  = balanced journals only (target is a ledger)
    -- SUMMARY  = daily totals per account/dimension (lightest, least auditable)
    active          BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE ext_entity_config (                            -- each PT can be its own database/company there
    ext_system_id   SMALLINT NOT NULL REFERENCES ext_system,
    entity_id       SMALLINT NOT NULL REFERENCES entity,
    ext_company_ref VARCHAR(80) NOT NULL,                   -- database / company id in the target
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (ext_system_id, entity_id)
);

CREATE TABLE ext_account_map (                              -- our COA code -> their COA code
    ext_system_id   SMALLINT NOT NULL REFERENCES ext_system,
    entity_id       SMALLINT NOT NULL REFERENCES entity,
    account_id      INT NOT NULL REFERENCES account,
    ext_account_code VARCHAR(40) NOT NULL,
    PRIMARY KEY (ext_system_id, entity_id, account_id)
);

CREATE TABLE ext_id_map (                                   -- our record <-> their record (parties, items, docs)
    ext_system_id   SMALLINT NOT NULL REFERENCES ext_system,
    entity_id       SMALLINT NOT NULL REFERENCES entity,
    object_type     VARCHAR(20) NOT NULL,                   -- PARTY, ITEM, AR_INVOICE, JOURNAL, TAX_INVOICE ...
    local_id        BIGINT NOT NULL,
    ext_id          VARCHAR(80) NOT NULL,
    ext_number      VARCHAR(60),
    synced_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (ext_system_id, entity_id, object_type, local_id)
);

CREATE TABLE ext_outbox (
    outbox_id       BIGSERIAL PRIMARY KEY,
    ext_system_id   SMALLINT NOT NULL REFERENCES ext_system,
    entity_id       SMALLINT NOT NULL REFERENCES entity,
    object_type     VARCHAR(20) NOT NULL,
    local_id        BIGINT NOT NULL,
    operation       VARCHAR(8) NOT NULL CHECK (operation IN ('CREATE','UPDATE','VOID')),
    payload         JSONB NOT NULL,                         -- exactly what was/will be sent
    idempotency_key VARCHAR(100) NOT NULL UNIQUE,           -- e.g. ACCURATE:DST01:AR_INVOICE:123:CREATE
    status          VARCHAR(10) NOT NULL DEFAULT 'QUEUED' CHECK (status IN
                      ('QUEUED','SENDING','SENT','FAILED','DEAD','SKIPPED')),
    attempts        SMALLINT NOT NULL DEFAULT 0,
    last_error      TEXT,
    response        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at         TIMESTAMPTZ
);
CREATE INDEX ON ext_outbox (status, ext_system_id);

-- ---------------------------------------------------------------------
-- 11. REPORTING VIEWS
-- ---------------------------------------------------------------------

CREATE VIEW v_trial_balance AS
SELECT j.entity_id, e.code AS entity_code, fp.year, fp.month,
       a.code AS account_code, a.name_id, a.account_class,
       SUM(l.debit) AS debit, SUM(l.credit) AS credit,
       SUM(l.debit - l.credit) AS net
  FROM journal j
  JOIN journal_line l USING (journal_id)
  JOIN account a USING (account_id)
  JOIN fiscal_period fp USING (period_id)
  JOIN entity e ON e.entity_id = j.entity_id
 WHERE j.status = 'POSTED'
 GROUP BY j.entity_id, e.code, fp.year, fp.month, a.code, a.name_id, a.account_class;

-- Group consolidation BEFORE elimination; ELIMINATION journals live in a
-- dedicated group entity or are tagged journal_type = 'ELIMINATION'.
CREATE VIEW v_group_trial_balance AS
SELECT year, month, account_code, name_id, account_class,
       SUM(debit) AS debit, SUM(credit) AS credit, SUM(net) AS net
  FROM v_trial_balance
 GROUP BY year, month, account_code, name_id, account_class;

-- Intercompany balances that must net to zero across the group.
CREATE VIEW v_interco_mismatch AS
SELECT LEAST(j.entity_id, l.partner_entity_id)    AS entity_a,
       GREATEST(j.entity_id, l.partner_entity_id) AS entity_b,
       fp.year, fp.month,
       SUM(l.debit - l.credit) AS net_should_be_zero
  FROM journal j
  JOIN journal_line l USING (journal_id)
  JOIN account a USING (account_id)
  JOIN fiscal_period fp USING (period_id)
 WHERE j.status = 'POSTED' AND a.is_intercompany
   AND a.account_class IN ('ASSET','LIABILITY')   -- receivable vs payable must mirror; P&L is eliminated separately
 GROUP BY 1,2,3,4
HAVING SUM(l.debit - l.credit) <> 0;

-- PPN keluaran vs masukan per masa pajak, from the tax documents.
CREATE VIEW v_ppn_position AS
SELECT entity_id, tax_period,
       SUM(CASE WHEN direction='KELUARAN' AND coretax_status='APPROVED' THEN ppn_amount ELSE 0 END) AS ppn_keluaran,
       SUM(CASE WHEN direction='MASUKAN'  AND coretax_status='APPROVED' THEN ppn_amount ELSE 0 END) AS ppn_masukan,
       SUM(CASE WHEN direction='KELUARAN' AND coretax_status='APPROVED' THEN ppn_amount ELSE -ppn_amount END)
         FILTER (WHERE coretax_status='APPROVED') AS ppn_payable,
       COUNT(*) FILTER (WHERE coretax_status IN ('PENDING','REJECTED')) AS faktur_not_approved
  FROM tax_invoice
 GROUP BY entity_id, tax_period;

-- Ledger PPN vs Coretax documents: any gap is a compliance issue.
CREATE VIEW v_ppn_ledger_vs_faktur AS
SELECT j.entity_id, to_char(j.journal_date,'YYYYMM') AS tax_period,
       SUM(l.credit - l.debit) AS ppn_keluaran_in_ledger
  FROM journal j JOIN journal_line l USING (journal_id)
  JOIN tax_code t ON t.output_account = l.account_id AND t.tax_type = 'PPN'
 WHERE j.status = 'POSTED'
 GROUP BY 1,2;

-- Aged receivables per entity (unpaid portion).
CREATE VIEW v_ar_ageing AS
SELECT i.entity_id, i.party_id, i.invoice_no, i.due_date, i.total_amount,
       i.total_amount - COALESCE(SUM(pa.amount) FILTER (WHERE p.payment_id IS NOT NULL),0) AS open_amount,
       GREATEST(CURRENT_DATE - i.due_date, 0) AS days_overdue,
       CASE WHEN CURRENT_DATE <= i.due_date THEN 'CURRENT'
            WHEN CURRENT_DATE - i.due_date <= 30 THEN '1-30'
            WHEN CURRENT_DATE - i.due_date <= 60 THEN '31-60'
            WHEN CURRENT_DATE - i.due_date <= 90 THEN '61-90'
            ELSE '>90' END AS bucket
  FROM ar_invoice i
  LEFT JOIN payment_allocation pa ON pa.ar_invoice_id = i.invoice_id
  LEFT JOIN payment p ON p.payment_id = pa.payment_id AND p.status = 'POSTED'
 WHERE i.status = 'POSTED'
 GROUP BY i.invoice_id
HAVING i.total_amount - COALESCE(SUM(pa.amount) FILTER (WHERE p.payment_id IS NOT NULL),0) > 0;

-- ---------------------------------------------------------------------
-- 12. SEED: minimal COA skeleton + current PPN rule (VERIFY with tax consultant)
-- ---------------------------------------------------------------------

INSERT INTO account (code, name_id, name_en, account_class, normal_balance, is_postable, is_intercompany, is_control, sak_ep_line) VALUES
 ('1-1100','Kas dan Bank','Cash and bank','ASSET','D',TRUE,FALSE,FALSE,'Kas dan setara kas'),
 ('1-1300','Piutang Usaha','Trade receivables','ASSET','D',TRUE,FALSE,TRUE,'Piutang usaha'),
 ('1-1310','Piutang Usaha - Pihak Berelasi','Trade receivables - related parties','ASSET','D',TRUE,TRUE,TRUE,'Piutang usaha pihak berelasi'),
 ('1-1400','Persediaan Barang Dagang','Merchandise inventory','ASSET','D',TRUE,FALSE,TRUE,'Persediaan'),
 ('1-1500','PPN Masukan','VAT input','ASSET','D',TRUE,FALSE,FALSE,'Pajak dibayar di muka'),
 ('1-1510','PPh Dibayar di Muka','Prepaid income tax','ASSET','D',TRUE,FALSE,FALSE,'Pajak dibayar di muka'),
 ('2-1100','Utang Usaha','Trade payables','LIABILITY','C',TRUE,FALSE,TRUE,'Utang usaha'),
 ('2-1110','Utang Usaha - Pihak Berelasi','Trade payables - related parties','LIABILITY','C',TRUE,TRUE,TRUE,'Utang usaha pihak berelasi'),
 ('2-1300','PPN Keluaran','VAT output','LIABILITY','C',TRUE,FALSE,FALSE,'Utang pajak'),
 ('2-1310','Utang PPh','Income tax payable','LIABILITY','C',TRUE,FALSE,FALSE,'Utang pajak'),
 ('2-1400','Utang Komisi Penjualan','Sales commission payable','LIABILITY','C',TRUE,FALSE,FALSE,'Beban akrual'),
 ('3-1000','Modal Disetor','Paid-in capital','EQUITY','C',TRUE,FALSE,FALSE,'Modal'),
 ('3-2000','Saldo Laba','Retained earnings','EQUITY','C',TRUE,FALSE,FALSE,'Saldo laba'),
 ('4-1000','Penjualan','Sales','REVENUE','C',TRUE,FALSE,FALSE,'Pendapatan'),
 ('4-1010','Penjualan - Pihak Berelasi','Sales - related parties','REVENUE','C',TRUE,TRUE,FALSE,'Pendapatan'),
 ('4-1100','Potongan Penjualan','Sales discounts','REVENUE','D',TRUE,FALSE,FALSE,'Pendapatan'),
 ('5-1000','Harga Pokok Penjualan','Cost of goods sold','COGS','D',TRUE,FALSE,FALSE,'Beban pokok penjualan'),
 ('5-1010','HPP - Pembelian Pihak Berelasi','COGS - related-party purchases','COGS','D',TRUE,TRUE,FALSE,'Beban pokok penjualan'),
 ('6-1100','Beban Komisi Penjualan','Sales commission expense','EXPENSE','D',TRUE,FALSE,FALSE,'Beban penjualan');

INSERT INTO tax_code (code, tax_type, description, rate, dpp_num, dpp_den, faktur_code,
                      output_account, input_account, valid_from, legal_basis)
SELECT 'PPN_NONLUX','PPN','PPN 12% x DPP nilai lain 11/12 (non-luxury goods)', 12.0000, 11, 12, '04',
       (SELECT account_id FROM account WHERE code='2-1300'),
       (SELECT account_id FROM account WHERE code='1-1500'),
       DATE '2025-01-01','PMK 131/2024 Pasal 3';

-- Withholding codes: structure only, rates left NULL until the tax consultant confirms (VERIFY).
INSERT INTO tax_code (code, tax_type, description, rate, valid_from, legal_basis) VALUES
 ('PPH21_EMP','PPH21','PPh 21 employees (TER method) - rate from table, not fixed', NULL, DATE '2024-01-01','VERIFY'),
 ('PPH23_SVC','PPH23','PPh 23 on services received', NULL, DATE '2025-01-01','VERIFY'),
 ('PPH4_2_RENT','PPH4_2','PPh 4(2) final on building/warehouse rent', NULL, DATE '2025-01-01','VERIFY');
