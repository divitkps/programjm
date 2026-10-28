"""KPS Distributor Management System — web app (Phase 1 slice).

Screens: login · dashboard · stores · catalog · orders (new, list, detail, confirm) · approvals.
"""
import os
from decimal import Decimal, InvalidOperation
from pathlib import Path

import psycopg
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware

from .auth import NotLoggedIn, check_login, current_user, entity_filter, require_same_entity
from . import i18n
from .db import all_rows, one_row, tx

db_error_message = i18n.db_error_id

BASE = Path(__file__).parent
app = FastAPI(title="KPS Distributor System", docs_url=None, redoc_url=None)
app.add_middleware(
    SessionMiddleware,
    secret_key=os.environ.get("SESSION_SECRET", "change-me-in-production"),
    same_site="lax",
    https_only=os.environ.get("HTTPS_ONLY", "0") == "1",
    max_age=60 * 60 * 12,
)
app.mount("/static", StaticFiles(directory=BASE / "static"), name="static")
templates = Jinja2Templates(directory=BASE / "templates")


i18n.install(templates.env)


@app.exception_handler(NotLoggedIn)
async def _not_logged_in(request: Request, exc: NotLoggedIn):
    return RedirectResponse("/login", status_code=303)


def render(request, name, user=None, **ctx):
    return templates.TemplateResponse(request, name, {"user": user, **ctx})


def flash(request, text, kind="ok"):
    request.session["flash"] = {"text": text, "kind": kind}


def pop_flash(request):
    return request.session.pop("flash", None)


# ---------------------------------------------------------------- login

@app.get("/login", response_class=HTMLResponse)
def login_form(request: Request):
    return render(request, "login.html", error=None)


@app.post("/login")
def login(request: Request, email: str = Form(...), password: str = Form(...)):
    uid = check_login(email, password)
    if not uid:
        return render(request, "login.html", error="Email atau kata sandi salah.")
    request.session.clear()
    request.session["uid"] = uid
    return RedirectResponse("/", status_code=303)


@app.post("/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse("/login", status_code=303)


# ---------------------------------------------------------------- dashboard

@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request):
    user = current_user(request)
    cond, params = entity_filter(user, "e.entity_id")
    rows = all_rows(
        f"""
        SELECT e.entity_id, e.code, e.legal_name, e.margin_floor_pct,
               COALESCE(s.orders,0) AS orders, s.net, s.margin,
               CASE WHEN s.net > 0 THEN round(s.margin / s.net * 100, 1) END AS margin_pct,
               COALESCE(p.pending,0) AS pending,
               COALESCE(pp.pipe_orders,0) AS pipe_orders, pp.pipeline, COALESCE(pp.expired,0) AS expired,
               lk.above_matrix, ov.overdue,
               tg.revenue_target,
               CASE WHEN tg.revenue_target > 0 THEN round(COALESCE(s.net,0) / tg.revenue_target * 100, 1) END AS target_pct
          FROM entity e
          LEFT JOIN (SELECT entity_id, COUNT(*) orders, SUM(total_net) net, SUM(total_margin) margin
                       FROM sales_order
                      WHERE status IN ('CONFIRMED','DELIVERED')
                        AND date_trunc('month', order_date) = date_trunc('month', CURRENT_DATE)
                      GROUP BY entity_id) s USING (entity_id)
          LEFT JOIN (SELECT entity_id, COUNT(*) pipe_orders, SUM(total_net) pipeline,
                            COUNT(*) FILTER (WHERE approval_expired(order_id)) expired
                       FROM sales_order WHERE status = 'APPROVED'
                      GROUP BY entity_id) pp USING (entity_id)
          LEFT JOIN (SELECT o.entity_id, COUNT(*) pending FROM approval_request a
                       JOIN sales_order o USING (order_id) WHERE a.status = 'OPEN'
                      GROUP BY o.entity_id) p USING (entity_id)
          LEFT JOIN (SELECT entity_id, SUM(discount_above_matrix) above_matrix FROM v_discount_leakage
                      WHERE week >= date_trunc('month', CURRENT_DATE) GROUP BY entity_id) lk USING (entity_id)
          LEFT JOIN (SELECT entity_id, SUM(open_amount) overdue FROM v_overdue GROUP BY entity_id) ov USING (entity_id)
          LEFT JOIN (SELECT entity_id, SUM(revenue_target) revenue_target FROM sales_target
                      WHERE rep_id IS NULL AND period = date_trunc('month', CURRENT_DATE)::date
                      GROUP BY entity_id) tg USING (entity_id)
         WHERE e.entity_role = 'DISTRIBUTOR' AND e.active AND {cond}
         ORDER BY e.code""",
        params,
    )
    return render(request, "dashboard.html", user, rows=rows, flash=pop_flash(request))


# ---------------------------------------------------------------- stores

@app.get("/stores", response_class=HTMLResponse)
def stores(request: Request, q: str = ""):
    user = current_user(request)
    cond, params = entity_filter(user, "c.entity_id")
    params["q"] = f"%{q.strip()}%"
    rows = all_rows(
        f"""SELECT c.customer_id, c.store_name, c.city, c.grade_code, c.whatsapp_no,
                   chain_label(grade_steps_for(c.entity_id, c.grade_code, NULL, CURRENT_DATE)) AS standard,
                   c.wa_opt_in_at IS NOT NULL AS consent, e.code AS entity_code, t.name AS territory,
                   u.full_name AS rep
              FROM customer c JOIN entity e USING (entity_id) JOIN territory t USING (territory_id)
              LEFT JOIN app_user u ON u.user_id = c.rep_id
             WHERE {cond} AND c.active AND c.store_name ILIKE %(q)s
             ORDER BY c.store_name LIMIT 200""",
        params,
    )
    return render(request, "stores.html", user, rows=rows, q=q, flash=pop_flash(request))


@app.get("/stores/new", response_class=HTMLResponse)
def store_form(request: Request):
    user = current_user(request)
    cond, params = entity_filter(user, "t.entity_id")
    territories = all_rows(f"SELECT territory_id, t.name, e.code FROM territory t JOIN entity e USING (entity_id) WHERE {cond} ORDER BY e.code, t.name", params)
    cond2, params2 = entity_filter(user, "entity_id")
    reps = all_rows(f"SELECT user_id, full_name FROM app_user WHERE role = 'SALES_REP' AND active AND {cond2} ORDER BY full_name", params2)
    grades = all_rows(
        f"""SELECT g.entity_id, g.grade_code, g.name, e.code,
                   chain_label(grade_steps_for(g.entity_id, g.grade_code, NULL, CURRENT_DATE)) AS standard
              FROM store_grade g JOIN entity e USING (entity_id) WHERE {cond2.replace('entity_id', 'g.entity_id')}
             ORDER BY e.code, g.grade_code""", params2)
    return render(request, "store_form.html", user, territories=territories, reps=reps, grades=grades,
                  error=None, form={}, flash=pop_flash(request))


@app.post("/stores/new")
def store_create(request: Request, store_name: str = Form(...), territory_id: int = Form(...),
                 rep_id: int = Form(None), grade_code: str = Form(...), owner_name: str = Form(""),
                 whatsapp_no: str = Form(""), consent: str = Form(None), city: str = Form(""),
                 npwp: str = Form(""), address: str = Form("")):
    user = current_user(request)
    terr = one_row("SELECT entity_id FROM territory WHERE territory_id = %(t)s", {"t": territory_id})
    if not terr:
        flash(request, "Wilayah tidak dikenal.", "error")
        return RedirectResponse("/stores/new", status_code=303)
    require_same_entity(user, terr["entity_id"])
    wa = "".join(ch for ch in whatsapp_no if ch.isdigit()) or None
    if wa and wa.startswith("0"):
        wa = "62" + wa[1:]
    try:
        with tx() as conn:
            conn.execute(
                """INSERT INTO customer (entity_id, territory_id, rep_id, store_name, owner_name, grade_code,
                                        whatsapp_no, wa_opt_in_at, npwp, city, address)
                   VALUES (%(e)s, %(t)s, %(r)s, %(n)s, %(o)s, %(g)s, %(w)s,
                           CASE WHEN %(consent)s THEN now() END, %(npwp)s, %(city)s, %(addr)s)""",
                {"e": terr["entity_id"], "t": territory_id, "r": rep_id, "n": store_name.strip(),
                 "o": owner_name.strip() or None, "g": grade_code.split(":")[-1], "w": wa, "consent": bool(consent),
                 "npwp": npwp.strip() or None, "city": city.strip() or None, "addr": address.strip() or None},
            )
    except psycopg.Error as exc:
        flash(request, db_error_message(exc), "error")
        return RedirectResponse("/stores/new", status_code=303)
    flash(request, f"Toko {store_name} sudah ditambahkan.")
    return RedirectResponse("/stores", status_code=303)


# ---------------------------------------------------------------- catalog

@app.get("/catalog", response_class=HTMLResponse)
def catalog(request: Request, q: str = ""):
    user = current_user(request)
    stock_scope = "TRUE" if user["is_principal"] else "w.entity_id = %(scope_entity)s"
    rows = all_rows(
        f"""SELECT p.sku, p.name, p.category, p.status, pl.list_price,
                   COALESCE(SUM(s.on_hand - s.reserved) FILTER (WHERE {stock_scope}), 0) AS available
              FROM product p
              LEFT JOIN price_list pl ON pl.sku = p.sku AND pl.valid @> CURRENT_DATE
              LEFT JOIN stock s ON s.sku = p.sku
              LEFT JOIN warehouse w USING (warehouse_id)
             WHERE p.status <> 'DISCONTINUED' AND (p.sku ILIKE %(q)s OR p.name ILIKE %(q)s)
             GROUP BY p.sku, pl.list_price ORDER BY p.category, p.sku LIMIT 300""",
        {"q": f"%{q.strip()}%", "scope_entity": user["entity_id"]},
    )
    return render(request, "catalog.html", user, rows=rows, q=q)


# ---------------------------------------------------------------- orders

@app.get("/orders", response_class=HTMLResponse)
def orders(request: Request, status: str = ""):
    user = current_user(request)
    cond, params = entity_filter(user, "o.entity_id")
    if user["role"] == "SALES_REP":
        cond += " AND o.rep_id = %(me)s"
        params["me"] = user["user_id"]
    if status:
        cond += " AND o.status = %(st)s"
        params["st"] = status
    rows = all_rows(
        f"""SELECT o.order_id, o.order_no, o.order_date, o.status, o.required_level, o.order_type,
                   o.total_net, o.margin_pct, c.store_name, e.code AS entity_code, u.full_name AS rep
              FROM sales_order o JOIN customer c USING (customer_id) JOIN entity e ON e.entity_id = o.entity_id
              LEFT JOIN app_user u ON u.user_id = o.rep_id
             WHERE {cond} ORDER BY o.order_id DESC LIMIT 200""",
        params,
    )
    return render(request, "orders.html", user, rows=rows, status=status, flash=pop_flash(request))


@app.get("/orders/new", response_class=HTMLResponse)
def order_form(request: Request):
    user = current_user(request)
    cond, params = entity_filter(user, "c.entity_id")
    stores_ = all_rows(
        f"""SELECT customer_id, store_name, city, grade_code,
                   chain_label(grade_steps_for(entity_id, grade_code, NULL, CURRENT_DATE)) AS standard
              FROM customer c WHERE {cond} AND active ORDER BY store_name""", params)
    products = all_rows("SELECT p.sku, p.name FROM product p JOIN price_list pl ON pl.sku = p.sku AND pl.valid @> CURRENT_DATE WHERE p.status <> 'DISCONTINUED' ORDER BY p.sku")
    return render(request, "order_form.html", user, stores=stores_, products=products, line_count=6,
                  flash=pop_flash(request))


@app.post("/orders/new")
async def order_create(request: Request):
    user = current_user(request)
    form = await request.form()
    customer_id = int(form.get("customer_id") or 0)
    order_type = form.get("order_type", "REGULAR")
    store = one_row("SELECT entity_id, rep_id FROM customer WHERE customer_id = %(c)s", {"c": customer_id})
    if not store:
        flash(request, "Pilih toko terlebih dahulu.", "error")
        return RedirectResponse("/orders/new", status_code=303)
    require_same_entity(user, store["entity_id"])

    lines = []
    for i in range(20):
        sku, qty = (form.get(f"sku_{i}") or "").strip(), form.get(f"qty_{i}")
        extra, price = (form.get(f"extra_{i}") or "0").replace(",", "."), (form.get(f"price_{i}") or "").replace(".", "").replace(",", "").strip()
        if sku and qty:
            try:
                qty_d, extra_d, price_d = Decimal(qty), Decimal(extra), (Decimal(price) if price else None)
            except (InvalidOperation, ValueError):
                flash(request, f"Baris {i + 1}: jumlah, diskon tambahan dan harga khusus harus berupa angka.", "error")
                return RedirectResponse("/orders/new", status_code=303)
            if price_d is not None and extra_d:
                flash(request, f"Baris {i + 1}: isi diskon tambahan atau harga khusus, jangan keduanya.", "error")
                return RedirectResponse("/orders/new", status_code=303)
            lines.append((sku, qty_d, extra_d, price_d))
    if not lines:
        flash(request, "Tambahkan minimal satu barang.", "error")
        return RedirectResponse("/orders/new", status_code=303)

    rep_id = user["user_id"] if user["role"] == "SALES_REP" else store["rep_id"]
    try:
        with tx() as conn:
            seq = conn.execute(
                "SELECT COUNT(*) + 1 AS n FROM sales_order WHERE entity_id = %(e)s", {"e": store["entity_id"]}
            ).fetchone()["n"]
            code = conn.execute("SELECT code FROM entity WHERE entity_id = %(e)s", {"e": store["entity_id"]}).fetchone()["code"]
            order = conn.execute(
                """INSERT INTO sales_order (entity_id, order_no, customer_id, rep_id, entered_by, order_type, channel)
                   VALUES (%(e)s, %(no)s, %(c)s, %(r)s, %(by)s, %(t)s, 'REP') RETURNING order_id""",
                {"e": store["entity_id"], "no": f"{code}-SO-{seq:05d}", "c": customer_id, "r": rep_id,
                 "by": user["user_id"], "t": order_type},
            ).fetchone()
            for sku, qty, extra, price in lines:
                conn.execute(
                    """INSERT INTO sales_order_line (order_id, sku, qty, extra_disc_pct, special_unit_price)
                       VALUES (%(o)s, %(s)s, %(q)s, %(x)s, %(p)s)""",
                    {"o": order["order_id"], "s": sku, "q": qty, "x": extra, "p": price},
                )
            level = conn.execute("SELECT price_order(%(o)s) AS level", {"o": order["order_id"]}).fetchone()["level"]
    except psycopg.Error as exc:
        flash(request, db_error_message(exc), "error")
        return RedirectResponse("/orders/new", status_code=303)

    flash_routing(request, order["order_id"], level)
    return RedirectResponse(f"/orders/{order['order_id']}", status_code=303)


ROUTING_MESSAGES = {
    "ABOVE_MATRIX": "Harga di bawah harga standar toko: dikirim ke manajer untuk persetujuan.",
    "BELOW_FLOOR": "Margin salah satu barang di bawah batas: dikirim ke prinsipal untuk persetujuan.",
    "ABOVE_HEAD_LIMIT": "Harga salah satu barang melebihi batas wewenang manajer: dikirim ke prinsipal.",
    "NO_HEAD_LIMIT": "Barang dengan harga di bawah standar belum punya batas manajer: dikirim ke prinsipal.",
}


def flash_routing(request, order_id, level):
    if level == "REP":
        flash(request, "Pesanan sesuai harga standar dan langsung disetujui.")
        return
    req = one_row("SELECT reason_code FROM approval_request WHERE order_id = %(o)s AND status = 'OPEN'", {"o": order_id})
    flash(request, ROUTING_MESSAGES.get(req["reason_code"] if req else "", "Dikirim untuk persetujuan."), "warn")


def can_cancel(user, order):
    if user["is_principal"]:
        return True
    if user["entity_id"] != order["entity_id"]:
        return False
    return user["role"] in {"DST_HEAD", "DST_ADMIN"} or (user["role"] == "SALES_REP" and order["rep_id"] == user["user_id"])


def can_deliver(user, order):
    return user["entity_id"] == order["entity_id"] and user["role"] in {"DST_HEAD", "DST_ADMIN", "WAREHOUSE"}


@app.get("/orders/{order_id}", response_class=HTMLResponse)
def order_detail(request: Request, order_id: int):
    user = current_user(request)
    order = one_row(
        """SELECT o.*, c.store_name, c.grade_code, e.code AS entity_code, e.margin_floor_pct, u.full_name AS rep
             FROM sales_order o JOIN customer c USING (customer_id) JOIN entity e ON e.entity_id = o.entity_id
             LEFT JOIN app_user u ON u.user_id = o.rep_id WHERE o.order_id = %(o)s""",
        {"o": order_id},
    )
    if not order:
        return RedirectResponse("/orders", status_code=303)
    require_same_entity(user, order["entity_id"])
    lines = all_rows(
        """SELECT l.*, p.name, chain_label(l.std_steps) AS standard FROM sales_order_line l JOIN product p USING (sku)
            WHERE order_id = %(o)s ORDER BY line_id""", {"o": order_id})
    approvals = all_rows(
        """SELECT a.*, u.full_name AS decider FROM approval_request a
             LEFT JOIN app_user u ON u.user_id = a.decided_by
            WHERE order_id = %(o)s ORDER BY request_id""", {"o": order_id})
    expired = one_row("SELECT approval_expired(%(o)s) AS x", {"o": order_id})["x"]
    valid_days = one_row("SELECT setting('approval_valid_days') AS d")["d"]
    return render(request, "order_detail.html", user, order=order, lines=lines, approvals=approvals,
                  expired=expired, valid_days=valid_days, may_cancel=can_cancel(user, order),
                  may_deliver=can_deliver(user, order), flash=pop_flash(request))


def _order_for_action(request, order_id):
    user = current_user(request)
    order = one_row("SELECT order_id, entity_id, rep_id, status FROM sales_order WHERE order_id = %(o)s", {"o": order_id})
    if not order:
        return user, None
    require_same_entity(user, order["entity_id"])
    return user, order


def _run_action(request, order_id, sql, params, ok_message):
    try:
        with tx() as conn:
            row = conn.execute(sql, params).fetchone()
        if callable(ok_message):
            ok_message(row)
        else:
            flash(request, ok_message)
    except psycopg.Error as exc:
        flash(request, db_error_message(exc), "error")
    return RedirectResponse(f"/orders/{order_id}", status_code=303)


@app.post("/orders/{order_id}/confirm")
def order_confirm(request: Request, order_id: int):
    user, order = _order_for_action(request, order_id)
    if not order:
        return RedirectResponse("/orders", status_code=303)
    return _run_action(request, order_id, "SELECT confirm_order(%(o)s)", {"o": order_id},
                       "Pesanan dikonfirmasi dan stok sudah dipesan.")


@app.post("/orders/{order_id}/deliver")
def order_deliver(request: Request, order_id: int):
    user, order = _order_for_action(request, order_id)
    if not order:
        return RedirectResponse("/orders", status_code=303)
    if not can_deliver(user, order):
        flash(request, "Hanya gudang, admin atau manajer yang dapat mencatat pengiriman.", "error")
        return RedirectResponse(f"/orders/{order_id}", status_code=303)
    return _run_action(request, order_id, "SELECT deliver_order(%(o)s, %(u)s)",
                       {"o": order_id, "u": user["user_id"]}, "Terkirim: stok sudah keluar dari gudang.")


@app.post("/orders/{order_id}/cancel")
def order_cancel(request: Request, order_id: int, reason: str = Form("")):
    user, order = _order_for_action(request, order_id)
    if not order:
        return RedirectResponse("/orders", status_code=303)
    if not can_cancel(user, order):
        flash(request, "Anda tidak dapat membatalkan pesanan ini.", "error")
        return RedirectResponse(f"/orders/{order_id}", status_code=303)
    return _run_action(request, order_id, "SELECT cancel_order(%(o)s, %(u)s, %(r)s)",
                       {"o": order_id, "u": user["user_id"], "r": reason}, "Pesanan dibatalkan; stok yang dipesan sudah dilepas.")


@app.post("/orders/{order_id}/reprice")
def order_reprice(request: Request, order_id: int):
    user, order = _order_for_action(request, order_id)
    if not order:
        return RedirectResponse("/orders", status_code=303)
    return _run_action(request, order_id, "SELECT reprice_order(%(o)s) AS level", {"o": order_id},
                       lambda row: flash_routing(request, order_id, row["level"]))


# ---------------------------------------------------------------- approvals

@app.get("/approvals", response_class=HTMLResponse)
def approvals(request: Request):
    user = current_user(request)
    rows = all_rows(
        """SELECT a.request_id, a.level, a.reason_code, a.created_at, a.context,
                  o.order_id, o.order_no, o.total_net, o.margin_pct, o.order_type,
                  c.store_name, c.customer_class, e.code AS entity_code, e.margin_floor_pct, u.full_name AS rep,
                  round(EXTRACT(EPOCH FROM now() - a.created_at) / 3600, 1) AS hours_waiting
             FROM approval_request a
             JOIN sales_order o USING (order_id)
             JOIN customer c USING (customer_id)
             JOIN entity e ON e.entity_id = o.entity_id
             LEFT JOIN app_user u ON u.user_id = o.rep_id
            WHERE a.status = 'OPEN' AND can_decide(%(u)s, a.request_id)
            ORDER BY a.created_at""",
        {"u": user["user_id"]},
    )
    return render(request, "approvals.html", user, rows=rows, flash=pop_flash(request))


@app.post("/approvals/{request_id}")
def approval_decide(request: Request, request_id: int, decision: str = Form(...), note: str = Form("")):
    user = current_user(request)
    try:
        with tx() as conn:
            conn.execute("SELECT decide_approval(%(r)s, %(u)s, %(d)s, %(n)s)",
                         {"r": request_id, "u": user["user_id"], "d": decision, "n": note})
        flash(request, {"APPROVE": "Disetujui.", "REJECT": "Ditolak.", "PASS_UP": "Diteruskan ke prinsipal."}[decision])
    except psycopg.Error as exc:
        flash(request, db_error_message(exc), "error")
    return RedirectResponse("/approvals", status_code=303)


@app.get("/health")
def health():
    one_row("SELECT 1 AS ok")
    return {"ok": True}
