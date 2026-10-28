"""Simulation: load the Jaya Mandiri (jm) VB database into a separate DMS database and
replay its 2025-2026 sales through the DMS pricing and approval rules.

The jm database is only read (read-only transaction). Everything is written to SIM_DATABASE_URL,
which is wiped and rebuilt on every run. Never point SIM_DATABASE_URL at real DMS data.

Usage:
    JM_SOURCE_URL=postgresql://user:pass@host/jm \
    SIM_DATABASE_URL=postgresql://user:pass@localhost:5433/kps_jm \
    python scripts/import_jm.py [--from 2025-01-01] [--open-days 7]

Simulation assumptions (all derived from jm history, none are company decisions):
  - National list price = jm item.item_price (PPN included, like jm's selling prices).
  - Line net price = line sub_total / qty, less the line's share of the invoice chain discount.
  - Principal -> distributor chain = one step: median of (item cost x 1.11) / list price.
  - Store grades = jm customer types; a grade's standard chain = one step: median discount off list
    in the replay period, per category where a grade has at least MIN_LINES lines in it.
  - Head may approve up to HEAD_MAX_EXTRA % extra discount below standard, for every category.
  - Distributor margin floor = MARGIN_FLOOR %; commission 0 % (jm records none).
"""
import argparse
import os
import re
import sys
from collections import defaultdict
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path

import psycopg
from passlib.hash import bcrypt

ROOT = Path(__file__).resolve().parents[1]
SOURCE_URL = os.environ.get("JM_SOURCE_URL")
SIM_URL = os.environ.get("SIM_DATABASE_URL")

DEMO_PASSWORD = "demo1234"
MARGIN_FLOOR = 10
HEAD_MAX_EXTRA = 5
MIN_LINES = 20
PPN = Decimal("1.11")
TOKEN_SHARE = Decimal("0.01")
GRADES = {"01": ("DK", "Dalam Kota"), "02": ("LK", "Luar Kota"),
          "03": ("PRY", "Proyek"), "05": ("EXT", "External")}


def cut(text, n):
    text = (text or "").strip()
    return text[:n] if text else None


def slug(name):
    return re.sub(r"[^a-z0-9]+", ".", name.lower()).strip(".") or "user"


# ---------------------------------------------------------------- read jm (read-only)
def read_source(since):
    with psycopg.connect(SOURCE_URL) as src:
        src.read_only = True
        q = lambda sql, p=None: src.execute(sql, p).fetchall()
        main_loc = q("SELECT location_id FROM location WHERE location_name = 'JAYA MANDIRI'")[0][0]
        data = {
            "items": q("""SELECT i.item_code, i.item_name, k.description, i.item_price, u.unit_code
                            FROM item i LEFT JOIN kategori k USING (kategori_id)
                            LEFT JOIN unit u ON u.unit_id = i.unit_id"""),
            "customers": q("""SELECT c.customer_id, c.customer_name, ct.customer_type_code, c.contact_name1,
                                     c.address, c.city, c.credit_limit, c.default_employee_id
                                FROM customer c LEFT JOIN customer_type ct USING (customer_type_id)"""),
            "employees": q("SELECT employee_id, employee_name, job_title FROM employee"),
            "stock": q("""SELECT item_code, SUM(current_qty) FROM inventory_location
                           WHERE location_id = %s GROUP BY 1 HAVING SUM(current_qty) > 0""", (main_loc,)),
            "lines": q("""SELECT t.sales_transaction_id, t.invoice_no, t.transaction_date::date, t.customer_id,
                                 t.sales_id, t.total_amount, d.item_code, d.qty, d.sub_total, d.item_cost
                            FROM sales_transaction t JOIN sales_transaction_detail d USING (sales_transaction_id)
                           WHERE t.status = 2 AND t.transaction_date >= %s AND d.qty > 0
                           ORDER BY t.transaction_date, t.sales_transaction_id, d.index_no""", (since,)),
            "receivables": q("""SELECT invoice_no, transaction_date::date, due_date::date, customer_id,
                                       total_amount - paid_amount
                                  FROM sales_transaction
                                 WHERE status = 2 AND total_amount > paid_amount + 1"""),
        }
    return data


# ---------------------------------------------------------------- rebuild the simulation database
def rebuild_schema(conn):
    conn.execute("DROP SCHEMA IF EXISTS core CASCADE")
    conn.execute("DROP SCHEMA IF EXISTS sim CASCADE")
    for path in sorted((ROOT / "db").glob("0*.sql")):
        conn.execute(path.read_text())
    conn.execute("SET search_path = core, public")
    conn.execute("""
        CREATE SCHEMA sim;
        CREATE TABLE sim.jm_line (
            txn_id TEXT, invoice_no TEXT, order_date DATE, customer_id BIGINT, rep_id INT,
            sku TEXT, category TEXT, grade_code TEXT, qty NUMERIC, net_unit NUMERIC,
            cost_unit NUMERIC, list_price NUMERIC);
        CREATE TABLE sim.replay (
            order_id BIGINT PRIMARY KEY, invoice_no TEXT, order_date DATE, level TEXT, reason TEXT,
            error TEXT);
        CREATE TABLE sim.assumption (key TEXT PRIMARY KEY, value TEXT);
    """)


def is_sale(row):
    """A line with a list price, sold above a token price (jm books samples and swaps at Rp 1)."""
    return bool(row[11]) and row[9] >= row[11] * TOKEN_SHARE


def median(values):
    v = sorted(values)
    if not v:
        return None
    m = len(v) // 2
    return v[m] if len(v) % 2 else (v[m - 1] + v[m]) / 2


def load(conn, data, since):
    x = lambda sql, p=None: conn.execute(sql, p)
    one = lambda sql, p=None: conn.execute(sql, p).fetchone()[0]
    h = bcrypt.hash(DEMO_PASSWORD)

    # entities and territories (one per jm customer type)
    x("""INSERT INTO entity (code, legal_name, entity_role, margin_floor_pct) VALUES
           ('PRN','Prinsipal (simulasi)','PRINCIPAL',NULL),
           ('JM','JAYA MANDIRI (simulasi)','DISTRIBUTOR',%s)""", (MARGIN_FLOOR,))
    prn, jm = 1, 2
    territory = {}
    for code, (grade, name) in GRADES.items():
        territory[code] = one("INSERT INTO territory (entity_id, code, name) VALUES (%s,%s,%s) RETURNING territory_id",
                              (jm, f"JM-{grade}", name))
        x("INSERT INTO store_grade (entity_id, grade_code, name) VALUES (%s,%s,%s)", (jm, grade, name))

    # users: principal, distributor head, and every rep seen in sales or as a store's default rep
    owner = one("""INSERT INTO app_user (entity_id, full_name, role, email, password_hash)
                   VALUES (%s,'Pemilik (simulasi)','OWNER','owner@jm.sim',%s) RETURNING user_id""", (prn, h))
    x("""INSERT INTO app_user (entity_id, full_name, role, reports_to, email, password_hash)
         VALUES (%s,'Direktur Penjualan (simulasi)','PRN_SALES_DIR',%s,'salesdir@jm.sim',%s)""", (prn, owner, h))
    employees = {e[0]: e for e in data["employees"]}
    used = {ln[4] for ln in data["lines"]} | {c[7] for c in data["customers"]}
    head_emp = next(e for e in data["employees"] if (e[2] or "").strip().lower() == "manager")
    emails, user_of = set(), {}

    def add_user(emp, role, reports_to):
        email = base = slug(emp[1])
        n = 1
        while email in emails:
            n += 1
            email = f"{base}{n}"
        emails.add(email)
        return one("""INSERT INTO app_user (entity_id, full_name, role, reports_to, email, password_hash)
                      VALUES (%s,%s,%s,%s,%s,%s) RETURNING user_id""",
                   (jm, cut(emp[1], 100), role, reports_to, f"{email}@jm.sim", h))

    head = user_of[head_emp[0]] = add_user(head_emp, "DST_HEAD", None)
    for emp_id in sorted(e for e in used if e in employees and e != head_emp[0]):
        user_of[emp_id] = add_user(employees[emp_id], "SALES_REP", head)

    # products and the national price list
    category_of, list_of = {}, {}
    for code, name, cat, price, uom in data["items"]:
        sku = cut(code, 40)
        category_of[sku] = cut(cat, 40) or "LAIN-LAIN"
        x("INSERT INTO product (sku, name, category, uom) VALUES (%s,%s,%s,%s) ON CONFLICT DO NOTHING",
          (sku, cut(name, 150) or sku, category_of[sku], cut(uom, 10) or "PCS"))
        if price and price > 0:
            list_of[sku] = price
            x("INSERT INTO price_list (sku, list_price, valid) VALUES (%s,%s,%s) ON CONFLICT DO NOTHING",
              (sku, price, f"[{since},)"))

    # stores
    store_of, grade_of = {}, {}
    for cid, name, type_code, contact, addr, city, limit, emp in data["customers"]:
        type_code = type_code if type_code in GRADES else "01"
        grade = GRADES[type_code][0]
        store_of[cid] = one("""INSERT INTO customer (entity_id, territory_id, rep_id, store_name, owner_name,
                                   grade_code, address, city, credit_limit)
                               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING customer_id""",
                            (jm, territory[type_code], user_of.get(emp), cut(name, 150) or "(tanpa nama)",
                             cut(contact, 100), grade, cut(addr, 255), cut(city, 60), limit or None))
        grade_of[store_of[cid]] = grade

    # stock in the main warehouse
    wh = one("INSERT INTO warehouse (entity_id, name) VALUES (%s,'Gudang JAYA MANDIRI') RETURNING warehouse_id", (jm,))
    for code, qty in data["stock"]:
        if cut(code, 40) in category_of:
            x("INSERT INTO stock (warehouse_id, sku, on_hand) VALUES (%s,%s,%s)", (wh, cut(code, 40), qty))

    # sales lines with their net price after the invoice chain discount
    line_sum = defaultdict(Decimal)
    for ln in data["lines"]:
        line_sum[ln[0]] += ln[8]
    staged = []
    for txn, inv, d, cid, emp, total, code, qty, sub, cost in data["lines"]:
        sku = cut(code, 40)
        factor = total / line_sum[txn] if line_sum[txn] else Decimal(0)
        staged.append((txn, inv, d, store_of.get(cid), user_of.get(emp), sku, category_of.get(sku),
                       grade_of.get(store_of.get(cid)), qty, sub / qty * factor, cost, list_of.get(sku)))
    with conn.cursor().copy("COPY sim.jm_line FROM STDIN") as cp:
        for row in staged:
            cp.write_row(row)

    # rules derived from history
    priced = [s for s in staged if is_sale(s)]
    # Buying price: one base chain for the distributor (the shallowest category), plus a principal
    # support discount per category so each category's landed cost matches jm's median cost.
    costed = defaultdict(list)
    for s in priced:
        if s[10] and s[10] > 0:
            costed[s[6]].append(s[10] * PPN / s[11])
    cat_buy = {cat: median(v) for cat, v in costed.items() if cat and len(v) >= MIN_LINES}
    buy = max(cat_buy.values())
    buy_step = round((1 - buy) * 100, 2)
    x("INSERT INTO distributor_discount (entity_id, disc_pct, valid, steps) VALUES (%s,0,%s,%s)",
      (jm, f"[{since},)", [buy_step]))
    for cat, f in sorted(cat_buy.items()):
        support = round((1 - f / buy) * 100, 2)
        if support > 0:
            x("""INSERT INTO support_discount (entity_id, category, disc_pct, kind, reason, valid, approved_by)
                 VALUES (%s,%s,%s,'SUPPORT','Simulasi: biaya beli jm historis per kategori',%s,%s)""",
              (jm, cat, support, f"[{since},)", owner))
    x("INSERT INTO commission_plan VALUES (%s,'REVENUE',0,%s)", (jm, f"[{since},)"))

    disc = lambda rows: min(max(round((1 - median([r[9] / r[11] for r in rows])) * 100, 2), Decimal(0)), Decimal("99"))
    overall = disc(priced)
    by_grade, by_grade_cat = defaultdict(list), defaultdict(list)
    for r in priced:
        by_grade[r[7]].append(r)
        by_grade_cat[(r[7], r[6])].append(r)
    rules = []
    for grade, _ in GRADES.values():
        g = by_grade.get(grade, [])
        g_step = disc(g) if len(g) >= MIN_LINES else overall
        x("INSERT INTO grade_discount (entity_id, grade_code, category, steps, valid) VALUES (%s,%s,NULL,%s,%s)",
          (jm, grade, [g_step], f"[{since},)"))
        rules.append((grade, "(semua)", g_step, len(g)))
        for (gg, cat), rows in sorted(by_grade_cat.items(), key=lambda kv: (kv[0][0], kv[0][1] or "")):
            if gg == grade and cat and len(rows) >= MIN_LINES:
                step = disc(rows)
                x("INSERT INTO grade_discount (entity_id, grade_code, category, steps, valid) VALUES (%s,%s,%s,%s,%s)",
                  (jm, grade, cat, [step], f"[{since},)"))
                rules.append((grade, cat, step, len(rows)))
    for cat in sorted(set(category_of.values())):
        x("INSERT INTO item_head_limit (category, max_disc_pct, valid, note) VALUES (%s,%s,%s,'Asumsi simulasi')",
          (cat, HEAD_MAX_EXTRA, f"[{since},)"))

    # monthly distributor target = the same month a year earlier
    x("""INSERT INTO sales_target (entity_id, rep_id, period, revenue_target)
         SELECT %s, NULL::int, (date_trunc('month', order_date) + INTERVAL '1 year')::date, SUM(qty * net_unit)
           FROM sim.jm_line WHERE order_date < %s::date + INTERVAL '1 year'
          GROUP BY 3 HAVING SUM(qty * net_unit) > 0""", (jm, since))

    x("INSERT INTO sim.assumption VALUES (%s,%s),(%s,%s),(%s,%s),(%s,%s),(%s,%s)",
      ("buy_chain_pct", str(buy_step), "overall_store_disc_pct", str(overall),
       "head_max_extra_pct", str(HEAD_MAX_EXTRA), "margin_floor_pct", str(MARGIN_FLOOR),
       "replay_from", str(since)))
    conn.commit()
    return jm, owner, head, staged, rules, buy_step, store_of


def replay(conn, staged, jm, owner, head, open_days):
    orders = defaultdict(list)
    for row in staged:
        orders[row[0]].append(row)
    skipped_lines = errors = 0
    cutoff = date.today() - timedelta(days=open_days)
    for txn, rows in orders.items():
        inv, d, store, rep = rows[0][1], rows[0][2], rows[0][3], rows[0][4]
        lines = [r for r in rows if is_sale(r)]
        skipped_lines += len(rows) - len(lines)
        if store is None or not lines:
            continue
        with conn.transaction():
            oid = conn.execute("""INSERT INTO sales_order (entity_id, order_no, customer_id, rep_id, entered_by, order_date)
                                  VALUES (%s,%s,%s,%s,%s,%s) RETURNING order_id""",
                               (jm, cut(inv, 30), store, rep, rep, d)).fetchone()[0]
            for r in lines:
                conn.execute("""INSERT INTO sales_order_line (order_id, sku, qty, special_unit_price)
                                VALUES (%s,%s,%s,%s)""", (oid, r[5], r[8], round(r[9], 2)))
            try:
                with conn.transaction():
                    conn.execute("SELECT price_order(%s)", (oid,))
                conn.execute("""INSERT INTO sim.replay
                                SELECT o.order_id, o.order_no, o.order_date, o.required_level, a.reason_code, NULL
                                  FROM sales_order o LEFT JOIN approval_request a USING (order_id)
                                 WHERE o.order_id = %s""", (oid,))
            except psycopg.Error as e:
                errors += 1
                conn.execute("INSERT INTO sim.replay VALUES (%s,%s,%s,NULL,NULL,%s)",
                             (oid, inv, d, str(e).splitlines()[0][:300]))
            else:
                # History older than the open window is closed as decided and delivered on its own
                # date, so later orders see the store's real history; the last days stay open.
                if d < cutoff:
                    close_as_history(conn, oid, head, owner)
    return len(orders), skipped_lines, errors


def close_as_history(conn, oid, head, owner):
    conn.execute("""
        UPDATE approval_request a SET status = 'APPROVED',
               decided_by = CASE WHEN a.level = 'MANAGER' AND o.entered_by IS DISTINCT FROM %(head)s
                                 THEN %(head)s ELSE %(owner)s END,
               decided_at = o.order_date, decision_note = 'Simulasi: transaksi historis jm (sudah terjadi)'
          FROM sales_order o
         WHERE o.order_id = a.order_id AND a.order_id = %(o)s AND a.status = 'OPEN'""",
                 {"head": head, "owner": owner, "o": oid})
    conn.execute("""
        UPDATE sales_order SET status = 'DELIVERED', approved_at = order_date,
               confirmed_at = order_date, delivered_at = order_date
         WHERE order_id = %s""", (oid,))


def load_receivables(conn, data, jm, store_of):
    """Unpaid jm invoices become open DMS invoices for the outstanding amount."""
    order_of = dict(conn.execute("SELECT order_no, order_id FROM sales_order WHERE entity_id = %s", (jm,)).fetchall())
    n = 0
    for inv, d, due, cid, amount in data["receivables"]:
        if cid in store_of and amount > 0:
            conn.execute("""INSERT INTO invoice (entity_id, invoice_no, order_id, customer_id, invoice_date,
                                                 due_date, total_amount)
                            VALUES (%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING""",
                         (jm, cut(inv, 30), order_of.get(cut(inv, 30)), store_of[cid], d, due or d, amount))
            n += 1
    conn.commit()
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="since", default="2025-01-01")
    ap.add_argument("--open-days", type=int, default=7)
    args = ap.parse_args()
    if not SOURCE_URL or not SIM_URL:
        sys.exit("Set JM_SOURCE_URL and SIM_DATABASE_URL")
    if "kps_jm" not in SIM_URL:
        sys.exit("SIM_DATABASE_URL is wiped on every run; it must name the kps_jm database")

    print("Reading jm (read-only)...")
    data = read_source(args.since)
    print(f"  {len(data['items'])} items, {len(data['customers'])} stores, {len(data['lines'])} sales lines")
    with psycopg.connect(SIM_URL) as conn:
        rebuild_schema(conn)
        jm, owner, head, staged, rules, buy_step, store_of = load(conn, data, args.since)
        print(f"Masters loaded. Principal -> distributor chain: {buy_step}%")
        for grade, cat, step, n in rules:
            print(f"  grade {grade:<4} {cat:<32} standard {step}%  ({n} lines)")
        total, skipped, errors = replay(conn, staged, jm, owner, head, args.open_days)
        print(f"Replayed {total} invoices ({skipped} lines without list price or at token price skipped, "
              f"{errors} pricing errors)")
        print(f"Open receivables loaded: {load_receivables(conn, data, jm, store_of)}")
    print(f"Done. Users: owner@jm.sim, salesdir@jm.sim, <name>@jm.sim — password {DEMO_PASSWORD}")


if __name__ == "__main__":
    main()
