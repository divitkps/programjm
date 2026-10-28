"""End-to-end tests of the selling flow against a real PostgreSQL database.

Run:  TEST_DATABASE_URL=postgresql://... pytest -q
The test database is dropped and rebuilt with demo data on every run.

Demo pricing (owner's example, 26 Oct 2026):
  distributor buys at 50%+3%+5% off list   -> pays 46.075% of list
  grade STD store buys at 40%+5% off list  -> pays 57%   of list
  grade PLUS store buys at 40%+5%+3%       -> pays 55.29% of list
  sales commission 3% of revenue; distributor default margin floor 10%; dining tables 15%
"""
import os
import re
import subprocess
import sys
from decimal import Decimal
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
TEST_URL = os.environ.get("TEST_DATABASE_URL")
if not TEST_URL:
    pytest.skip("TEST_DATABASE_URL not set", allow_module_level=True)
os.environ["DATABASE_URL"] = TEST_URL

subprocess.run([sys.executable, str(ROOT / "scripts" / "setup_db.py"), "--reset", "--demo"],
               check=True, env={**os.environ, "DATABASE_URL": TEST_URL}, capture_output=True)

from fastapi.testclient import TestClient  # noqa: E402

from app.db import one_row, tx  # noqa: E402
from app.main import app  # noqa: E402

JAYA, SENTOSA, SURYA = 1, 2, 4          # Jaya: DST01 grade STD · Sentosa: DST01 grade PLUS · Surya: DST02 grade STD


def client_as(email):
    c = TestClient(app)
    r = c.post("/login", data={"email": email, "password": "demo1234"}, follow_redirects=False)
    assert r.status_code == 303, f"login failed for {email}"
    return c


def order_form(store_id, lines, order_type="REGULAR"):
    data = {"customer_id": store_id, "order_type": order_type}
    for i, line in enumerate(lines):
        sku, qty, extra = line[0], line[1], line[2] if len(line) > 2 else 0
        special = line[3] if len(line) > 3 else ""
        data.update({f"sku_{i}": sku, f"qty_{i}": qty, f"extra_{i}": extra, f"price_{i}": special})
    return data


def new_order(c, store_id, lines, order_type="REGULAR"):
    r = c.post("/orders/new", data=order_form(store_id, lines, order_type), follow_redirects=False)
    assert r.status_code == 303
    m = re.match(r"/orders/(\d+)", r.headers["location"])
    assert m, f"order not created, redirected to {r.headers['location']}"
    return int(m.group(1))


def status_of(order_id):
    return one_row("SELECT status, required_level FROM sales_order WHERE order_id = %(o)s", {"o": order_id})


def open_request(order_id):
    return one_row("SELECT request_id, level FROM approval_request WHERE order_id = %(o)s AND status = 'OPEN'",
                   {"o": order_id})


def reason_of(order_id):
    r = one_row("SELECT reason_code FROM approval_request WHERE order_id = %(o)s AND status = 'OPEN'", {"o": order_id})
    return r["reason_code"] if r else None


def line_of(order_id, sku):
    return one_row("""SELECT chain_label(std_steps) AS standard, std_unit_price, net_unit_price, net_amount,
                             landed_cost, commission, margin, margin_pct, requested_disc_pct, extra_implied_pct, floor_pct
                        FROM sales_order_line WHERE order_id = %(o)s AND sku = %(s)s""", {"o": order_id, "s": sku})


def stock(sku="CAB-2D-01"):
    return one_row("SELECT on_hand, reserved FROM stock WHERE warehouse_id = 1 AND sku = %(s)s", {"s": sku})


# ------------------------------------------------------------ login and access

def test_wrong_password_is_refused():
    c = TestClient(app)
    r = c.post("/login", data={"email": "rep1@demo.kps", "password": "wrong"})
    assert "Email atau kata sandi salah" in r.text
    assert c.get("/", follow_redirects=False).status_code == 303


def test_every_screen_renders_for_every_role():
    for email in ["owner@demo.kps", "head1@demo.kps", "rep1@demo.kps"]:
        c = client_as(email)
        for path in ["/", "/orders", "/orders?status=APPROVED", "/orders/new", "/approvals",
                     "/stores", "/stores?q=Jaya", "/stores/new", "/catalog", "/catalog?q=CAB"]:
            r = c.get(path)
            assert r.status_code == 200, f"{email} {path} -> {r.status_code}"


def test_distributors_cannot_see_each_others_data():
    oid = new_order(client_as("rep1@demo.kps"), JAYA, [("CAB-2D-01", 1)])
    rep2 = client_as("rep2@demo.kps")
    assert rep2.get(f"/orders/{oid}").status_code == 404
    assert "Toko Mebel Jaya" not in rep2.get("/stores").text
    r = rep2.post("/orders/new", data=order_form(JAYA, [("CAB-2D-01", 1)]))
    assert r.status_code == 404
    owner = client_as("owner@demo.kps")
    dash = owner.get("/").text
    assert "DST01" in dash and "DST02" in dash
    assert "DST02" not in client_as("head1@demo.kps").get("/").text


# ------------------------------------------------------------ chain discounts and grades

def test_standard_price_follows_the_store_grade_chain():
    rep = client_as("rep1@demo.kps")
    std = new_order(rep, JAYA, [("CAB-2D-01", 2)])
    plus = new_order(rep, SENTOSA, [("CAB-2D-01", 1)])
    l = line_of(std, "CAB-2D-01")
    # 1,250,000 x 0.60 x 0.95 = 712,500; distributor pays 1,250,000 x 0.50 x 0.97 x 0.95 = 575,937.50
    assert l["standard"] == "40%+5%" and l["std_unit_price"] == 712500 and l["net_amount"] == 1425000
    assert l["landed_cost"] == Decimal("1151875.00") and l["commission"] == Decimal("42750.00")
    assert l["margin"] == Decimal("230375.00") and l["margin_pct"] == Decimal("16.17")
    assert l["requested_disc_pct"] == 43
    p = line_of(plus, "CAB-2D-01")
    assert p["standard"] == "40%+5%+3%" and p["std_unit_price"] == 691125      # 1,250,000 x 0.5529
    assert status_of(std)["status"] == "APPROVED" and status_of(plus)["status"] == "APPROVED"


def test_grade_rule_for_a_category_overrides_the_general_rule():
    oid = new_order(client_as("rep1@demo.kps"), JAYA, [("SHF-IP-01", 1)])
    assert line_of(oid, "SHF-IP-01")["standard"] == "40%+5%+5%"          # demo override for the RAK category


def test_selling_at_standard_needs_no_approval_and_rep_sees_no_margin():
    rep = client_as("rep1@demo.kps")
    oid = new_order(rep, JAYA, [("CAB-2D-01", 2)])
    assert status_of(oid) == {"status": "APPROVED", "required_level": "REP"}
    assert "Margin setelah komisi" not in rep.get(f"/orders/{oid}").text
    assert "Margin setelah komisi" in client_as("head1@demo.kps").get(f"/orders/{oid}").text


def test_special_price_above_standard_is_not_an_exception():
    oid = new_order(client_as("rep1@demo.kps"), JAYA, [("CAB-2D-01", 1, 0, 750000)])
    assert status_of(oid)["status"] == "APPROVED"


def test_extra_discount_and_special_price_together_are_refused():
    r = client_as("rep1@demo.kps").post("/orders/new", data=order_form(JAYA, [("CAB-2D-01", 1, 3, 700000)]),
                                        follow_redirects=True)
    assert "jangan keduanya" in r.text


def test_store_without_a_grade_cannot_take_orders():
    with tx() as conn:
        conn.execute("""INSERT INTO customer (entity_id, territory_id, rep_id, store_name)
                        VALUES (2, 1, 4, 'Toko Tanpa Grade')""")
    sid = one_row("SELECT customer_id FROM customer WHERE store_name = 'Toko Tanpa Grade'")["customer_id"]
    r = client_as("rep1@demo.kps").post("/orders/new", data=order_form(sid, [("CAB-2D-01", 1)]), follow_redirects=True)
    assert "belum punya klasifikasi" in r.text


def test_unknown_sku_is_reported_not_crashed():
    r = client_as("rep1@demo.kps").post("/orders/new", data=order_form(JAYA, [("NOPE-1", 1)]), follow_redirects=True)
    assert r.status_code == 200 and "Pesanan baru" in r.text


# ------------------------------------------------------------ approval routing

def test_extra_discount_within_head_limit_goes_to_head_then_rep_confirms():
    rep = client_as("rep1@demo.kps")
    oid = new_order(rep, JAYA, [("CAB-2D-01", 2, 3)])          # head may give up to 5% extra on this item
    assert status_of(oid) == {"status": "PENDING_APPROVAL", "required_level": "MANAGER"}
    assert reason_of(oid) == "ABOVE_MATRIX"
    req = open_request(oid)
    head = client_as("head1@demo.kps")
    assert f"/orders/{oid}" in head.get("/approvals").text
    r = head.post(f"/approvals/{req['request_id']}", data={"decision": "APPROVE", "note": ""}, follow_redirects=True)
    assert "wajib diisi" in r.text
    head.post(f"/approvals/{req['request_id']}", data={"decision": "APPROVE", "note": "Loyal store, slow month"})
    assert status_of(oid)["status"] == "APPROVED"
    before = stock()["reserved"]
    rep.post(f"/orders/{oid}/confirm")
    assert status_of(oid)["status"] == "CONFIRMED" and stock()["reserved"] - before == 2


def test_head_limit_in_percent_extra():
    rep = client_as("rep1@demo.kps")
    within = new_order(rep, JAYA, [("CAB-2D-01", 2, 5)])
    beyond = new_order(rep, JAYA, [("CAB-2D-01", 2, 6)])
    assert status_of(within)["required_level"] == "MANAGER"
    assert status_of(beyond)["required_level"] == "PRINCIPAL" and reason_of(beyond) == "ABOVE_HEAD_LIMIT"


def test_head_limit_in_rupiah_with_a_special_price():
    rep = client_as("rep1@demo.kps")
    within = new_order(rep, JAYA, [("CAB-3D-01", 1, 0, 1020000)])   # head may go down to Rp 1,000,000
    beyond = new_order(rep, JAYA, [("CAB-3D-01", 1, 0, 990000)])
    assert status_of(within)["required_level"] == "MANAGER"
    assert status_of(beyond)["required_level"] == "PRINCIPAL" and reason_of(beyond) == "ABOVE_HEAD_LIMIT"


def test_item_without_head_limit_goes_to_principal():
    oid = new_order(client_as("rep1@demo.kps"), JAYA, [("DSK-ST-01", 1, 2)])
    assert status_of(oid)["required_level"] == "PRINCIPAL" and reason_of(oid) == "NO_HEAD_LIMIT"
    assert one_row("SELECT COUNT(*) AS n FROM v_items_without_head_limit WHERE sku = 'DSK-ST-01'")["n"] == 1


def test_only_lines_below_standard_need_a_head_limit():
    oid = new_order(client_as("rep1@demo.kps"), JAYA, [("DSK-ST-01", 1), ("CAB-2D-01", 2, 3)])
    assert status_of(oid)["required_level"] == "MANAGER"


def test_below_floor_goes_to_principal_not_head():
    rep = client_as("rep1@demo.kps")
    oid = new_order(rep, JAYA, [("CAB-2D-01", 2, 9)])          # margin 8.2% < 10% floor
    assert line_of(oid, "CAB-2D-01")["margin_pct"] < 10
    assert status_of(oid)["required_level"] == "PRINCIPAL" and reason_of(oid) == "BELOW_FLOOR"
    req = open_request(oid)
    head = client_as("head1@demo.kps")
    assert f"/orders/{oid}" not in head.get("/approvals").text
    head.post(f"/approvals/{req['request_id']}", data={"decision": "APPROVE", "note": "try"})
    assert status_of(oid)["status"] == "PENDING_APPROVAL"
    client_as("owner@demo.kps").post(f"/approvals/{req['request_id']}",
                                     data={"decision": "REJECT", "note": "Margin too thin"})
    assert status_of(oid)["status"] == "REJECTED"


def test_margin_floor_is_checked_per_item():
    # A table 2% below standard has 14.5% margin, under the table floor of 15%,
    # while the whole order with 20 standard cabinets is above 15%.
    oid = new_order(client_as("rep1@demo.kps"), JAYA, [("CAB-2D-01", 20), ("TBL-DIN-01", 1, 2)])
    t = line_of(oid, "TBL-DIN-01")
    order = one_row("SELECT margin_pct FROM sales_order WHERE order_id = %(o)s", {"o": oid})
    assert t["floor_pct"] == 15 and t["margin_pct"] < 15 and order["margin_pct"] > 15
    assert status_of(oid)["required_level"] == "PRINCIPAL" and reason_of(oid) == "BELOW_FLOOR"


def test_plus_grade_at_standard_already_breaks_the_table_floor():
    # Finding from the owner's numbers: 40%+5%+3% leaves a table at 13.7% margin, under its 15% floor.
    rep = client_as("rep1@demo.kps")
    plus = new_order(rep, SENTOSA, [("TBL-DIN-01", 1)])
    std = new_order(rep, JAYA, [("TBL-DIN-01", 1)])
    assert line_of(plus, "TBL-DIN-01")["margin_pct"] == Decimal("13.67")
    assert reason_of(plus) == "BELOW_FLOOR"
    assert status_of(std)["status"] == "APPROVED"


def test_head_can_pass_a_request_up_to_the_principal():
    rep = client_as("rep1@demo.kps")
    oid = new_order(rep, JAYA, [("CAB-3D-01", 3, 3)])
    req = open_request(oid)
    assert req["level"] == "MANAGER"
    client_as("head1@demo.kps").post(f"/approvals/{req['request_id']}",
                                     data={"decision": "PASS_UP", "note": "Your call, new store"})
    assert open_request(oid)["level"] == "PRINCIPAL"
    assert "Your call, new store" in client_as("salesdir@demo.kps").get("/approvals").text


def test_nobody_decides_an_order_they_entered():
    head = client_as("head1@demo.kps")
    oid = new_order(head, JAYA, [("CAB-2D-01", 2, 3)])
    req = open_request(oid)
    assert f"/orders/{oid}" not in head.get("/approvals").text
    r = head.post(f"/approvals/{req['request_id']}", data={"decision": "APPROVE", "note": "mine"}, follow_redirects=True)
    assert "orang lain yang harus memutuskannya" in r.text
    client_as("owner@demo.kps").post(f"/approvals/{req['request_id']}",
                                     data={"decision": "APPROVE", "note": "checked by owner"})
    assert status_of(oid)["status"] == "APPROVED"


# ------------------------------------------------------------ after the decision

def test_confirm_fails_cleanly_without_stock():
    rep = client_as("rep1@demo.kps")
    oid = new_order(rep, JAYA, [("TBL-DIN-01", 16)])          # 15 in stock
    r = rep.post(f"/orders/{oid}/confirm", follow_redirects=True)
    assert "Stok TBL-DIN-01 tidak cukup" in r.text
    assert status_of(oid)["status"] == "APPROVED"


def test_cancel_releases_stock_and_delivery_takes_it_out():
    rep = client_as("rep1@demo.kps")
    start = stock()
    oid = new_order(rep, JAYA, [("CAB-2D-01", 3)])
    rep.post(f"/orders/{oid}/confirm")
    assert stock()["reserved"] - start["reserved"] == 3
    r = rep.post(f"/orders/{oid}/cancel", data={"reason": ""}, follow_redirects=True)
    assert "wajib diisi" in r.text
    rep.post(f"/orders/{oid}/cancel", data={"reason": "Store changed its mind"})
    assert status_of(oid)["status"] == "CANCELLED" and stock() == start

    oid2 = new_order(rep, JAYA, [("CAB-2D-01", 4)])
    rep.post(f"/orders/{oid2}/confirm")
    r = rep.post(f"/orders/{oid2}/deliver", follow_redirects=True)
    assert "Hanya gudang, admin atau manajer" in r.text
    client_as("head1@demo.kps").post(f"/orders/{oid2}/deliver")
    assert status_of(oid2)["status"] == "DELIVERED"
    assert stock() == {"on_hand": start["on_hand"] - 4, "reserved": start["reserved"]}
    mv = one_row("SELECT qty, movement_type FROM stock_movement WHERE ref_id = %(o)s", {"o": oid2})
    assert mv == {"qty": -4, "movement_type": "SALE"}
    r = rep.post(f"/orders/{oid2}/cancel", data={"reason": "too late"}, follow_redirects=True)
    assert "Pesanan berstatus Terkirim tidak dapat dibatalkan" in r.text


def test_cancel_withdraws_an_open_approval():
    rep = client_as("rep1@demo.kps")
    oid = new_order(rep, JAYA, [("CAB-2D-01", 2, 3)])
    req = open_request(oid)
    rep.post(f"/orders/{oid}/cancel", data={"reason": "Duplicate entry"})
    assert one_row("SELECT status FROM approval_request WHERE request_id = %(r)s",
                   {"r": req["request_id"]})["status"] == "WITHDRAWN"


def test_only_confirmed_orders_count_as_sales():
    with tx() as conn:
        conn.execute("DELETE FROM sales_order_line WHERE order_id IN (SELECT order_id FROM sales_order WHERE entity_id = 3)")
        conn.execute("DELETE FROM approval_request WHERE order_id IN (SELECT order_id FROM sales_order WHERE entity_id = 3)")
        conn.execute("DELETE FROM sales_order WHERE entity_id = 3")
    rep2 = client_as("rep2@demo.kps")
    oid = new_order(rep2, SURYA, [("CAB-2D-01", 10)])         # 10 x 712,500 = 7,125,000

    def dst02_sales():
        return one_row("SELECT COALESCE(actual_net,0) AS net FROM v_target_progress WHERE entity_id = 3 AND rep_id IS NULL")["net"]
    assert dst02_sales() == 0
    assert "Rp 7.125.000" in client_as("head2@demo.kps").get("/").text      # shown as pipeline
    rep2.post(f"/orders/{oid}/confirm")
    assert dst02_sales() == 7125000


def test_approval_expires_after_one_week_and_is_repriced():
    assert one_row("SELECT value FROM app_setting WHERE key = 'approval_valid_days'")["value"] == 7
    rep = client_as("rep1@demo.kps")
    oid = new_order(rep, JAYA, [("CAB-2D-01", 2)])
    with tx() as conn:
        conn.execute("UPDATE sales_order SET approved_at = now() - interval '8 days', order_date = CURRENT_DATE - 8 WHERE order_id = %(o)s", {"o": oid})
        conn.execute("UPDATE price_list SET valid = daterange(lower(valid), CURRENT_DATE) WHERE sku = 'CAB-2D-01' AND upper_inf(valid)")
        conn.execute("INSERT INTO price_list (sku, list_price, valid) VALUES ('CAB-2D-01', 1300000, daterange(CURRENT_DATE, NULL))")
    assert "Hitung ulang dengan aturan hari ini" in rep.get(f"/orders/{oid}").text
    r = rep.post(f"/orders/{oid}/confirm", follow_redirects=True)
    assert "Persetujuan sudah kedaluwarsa" in r.text
    rep.post(f"/orders/{oid}/reprice")
    o = one_row("SELECT status, order_date = CURRENT_DATE AS today, total_net FROM sales_order WHERE order_id = %(o)s", {"o": oid})
    assert o == {"status": "APPROVED", "today": True, "total_net": 1482000}   # 1,300,000 x 0.57 x 2
    rep.post(f"/orders/{oid}/confirm")
    assert status_of(oid)["status"] == "CONFIRMED"


# ------------------------------------------------------------ stores

def test_new_store_needs_a_grade_of_its_own_distributor():
    head = client_as("head1@demo.kps")
    head.post("/stores/new", data={"store_name": "Toko Baru", "territory_id": 1, "grade_code": "2:PLUS",
                                   "whatsapp_no": "0812-3456-7890", "consent": "1"})
    s = one_row("SELECT whatsapp_no, grade_code, wa_opt_in_at IS NOT NULL AS consent FROM customer WHERE store_name = 'Toko Baru'")
    assert s == {"whatsapp_no": "6281234567890", "grade_code": "PLUS", "consent": True}
    r = head.post("/stores/new", data={"store_name": "Wrong", "territory_id": 3, "grade_code": "3:STD"},
                  follow_redirects=False)
    assert r.status_code == 404                                 # DST02's territory
