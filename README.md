# KPS Distributor Management System (DMS)

Web system for a furniture principal that runs its owned distributors like branches.
This is **Phase 1, slice 1**: the selling flow with discount control.

## What works now

| Screen | Who | What it does |
| --- | --- | --- |
| Login | Everyone | Email and password; each user sees only their own distributor (principal sees all) |
| Dashboard | Everyone | This month per distributor: net sales, target %, margin vs floor, discount above matrix, approvals waiting, overdue receivables |
| Orders → New | Reps, heads | Store, items, quantity, requested discount → priced automatically and routed to the right approver |
| Order detail | Everyone (own distributor) | Lines vs discount matrix, approval history, confirm button that reserves stock |
| Approvals | Distributor head, owner, sales director | Context to decide (margin, store history, stock, rep target); approve, reject, or pass to principal; reason required |
| Stores | Everyone | Store registry per distributor with territory, rep, class, WhatsApp consent |
| Catalog | Everyone | Active products, list price, available stock |

Rules enforced by the database (not just the screens): discount matrix and margin floor routing,
who may approve what, one territory per distributor, AI messages only to stores with consent,
no overlapping prices or discount rules, every approval needs a reason, no task closes without an outcome.

Reps do not see the distributor's buying cost or margin; heads and the principal do.

## Language

The whole interface is in **Bahasa Indonesia**: screens, buttons, statuses, messages, numbers
(`Rp 1.234.567`, `16,2%`) and dates (`26 Okt 2026`). The database raises its messages in English for
developers and logs; `app/i18n.py` translates every one before it reaches a screen.
`tests/test_bahasa.py` fails if a database message has no translation, or if any screen shows English
words or raw codes. When adding a screen or a database message, add its Indonesian text in the same change.

## Business rules the system enforces

**Pricing (owner's model, 26 Oct 2026)**

- One national price list for everyone.
- Principal → distributor: a chain discount off the list, e.g. 50%+3%+5% (= 46.075% of list). `core.distributor_discount.steps`
- Distributor → store: the store's **grade** sets a standard chain discount, e.g. 40%+5%, or 40%+5%+3% for certain grades. A grade can have a different chain for a category. `core.store_grade`, `core.grade_discount`, `core.customer.grade_code`
- Chain discounts multiply: 40%+5% = 0.60 × 0.95 = 57% of list (43% off), not 45% off.
- Selling at the store's standard price needs no approval. An **extra discount** on top of the standard, or a **special price per unit** below it, is an exception.

**Routing**

1. Any item below its margin floor → principal. Floors per SKU or category, else the distributor default. `core.item_margin_floor`
2. Any line below the store's standard price → distributor head if every such line is within the head's limit for that item, else principal. Head limit per SKU or category: a minimum unit price (Rp) **or** a maximum extra discount on top of standard (%). Items with no head limit → principal. `core.item_head_limit`
3. Otherwise approved by rule.
4. Nobody decides an order they entered. Approvals are valid for 7 days, then the order must be re-priced. `core.app_setting`

**Checklists after loading real data**: `core.v_stores_without_grade` (stores that cannot take orders), `core.v_items_without_head_limit`.

The quantity-band matrix (`core.discount_rule`) from an earlier version is no longer used for pricing.
Demo grades, floors and head limits are examples only.

## Run it locally

Requirements: Python 3.12+, PostgreSQL 16.

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
createdb kps
export DATABASE_URL=postgresql://USER:PASSWORD@localhost:5432/kps
python scripts/setup_db.py --demo          # schema + demo data
uvicorn app.main:app --reload
```

Open http://localhost:8000. Demo users (password `demo1234`):

| Email | Role |
| --- | --- |
| owner@demo.kps | Owner (principal) |
| salesdir@demo.kps | Principal sales director |
| head1@demo.kps | Head of DST01 |
| rep1@demo.kps | Sales rep, DST01 |
| head2@demo.kps / rep2@demo.kps | DST02 |

Demo discount rules are examples only, not the company's real matrix.

## Tests

```bash
createdb kps_test
TEST_DATABASE_URL=postgresql://USER:PASSWORD@localhost:5432/kps_test pytest -q
```

The test database is wiped and rebuilt on every run. Never point it at real data.

## Deploying (production)

Needs a server, not shared cPanel hosting: a small VPS (Ubuntu 24.04, 2 vCPU, 4 GB RAM is enough for the pilot).

1. Install PostgreSQL 16 and Python 3.12; create a database and a user with a strong password.
2. Copy this repository; create the virtual environment and install requirements.
3. Set environment variables in a systemd unit or `.env`:
   - `DATABASE_URL` – production database
   - `SESSION_SECRET` – long random string (e.g. `python -c "import secrets;print(secrets.token_hex(32))"`)
   - `HTTPS_ONLY=1`
4. `python scripts/setup_db.py` (no `--demo` in production).
5. Run `uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 2` under systemd.
6. Put Caddy or Nginx in front for HTTPS on your domain.
7. Daily database backup off the server (`pg_dump`), and test a restore before go-live.

## Project layout

```
app/main.py          routes (screens)
app/auth.py          login, roles, which distributor a user may see
app/db.py            database connection
app/templates/       HTML screens
app/static/          stylesheet
db/001_core_schema.sql   tables, pricing and approval rules, reporting views
db/002_app.sql           logins, approval decisions, order confirmation
db/parked_accounting_schema.sql   accounting design, parked until the accounting program is chosen
scripts/setup_db.py  create schema, load demo data
tests/test_flow.py   end-to-end tests of the selling flow
```

## Known limits of this slice

- Order numbers use a simple per-distributor counter; two orders saved in the same instant can clash (the second gets an error and can be resaved). Replace with a per-distributor sequence before go-live.
- No screens yet for maintaining products, price list, discount matrix, users or targets; these are loaded by script for now.
- No invoices or payments screens yet; receivables come from data loads.
- Delivery is all-or-nothing per order; partial deliveries and returns are not built yet.
- Stock for one order line must sit in one warehouse.
- No migration from VB yet; waiting for the pilot distributor's database copy.
- English interface; Bahasa Indonesia to be added.
