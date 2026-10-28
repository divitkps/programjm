"""Everything a user sees must be in Bahasa Indonesia.

1. Every message the database can raise has an Indonesian translation in app/i18n.py.
2. Every screen, for every role, with real orders on it, contains none of the English
   words the interface used to show, and no raw code values like PENDING_APPROVAL.
3. Numbers use Indonesian formats.
"""
import html
import re
from pathlib import Path

import pytest

from tests.test_flow import JAYA, SENTOSA, client_as, new_order, open_request  # noqa: F401  (rebuilds the test db)

from app import i18n

ROOT = Path(__file__).resolve().parents[1]

ENGLISH_WORDS = [
    "Order", "Orders", "Store", "Stores", "Approve", "Reject", "Approved", "Rejected", "Pending",
    "Confirmed", "Delivered", "Cancelled", "Search", "Save", "Cancel", "Log out", "Sign in",
    "Dashboard", "Catalog", "Waiting", "Quantity", "Price", "Discount", "Reason", "required",
    "standard", "Stock", "not set", "expired", "Net sales", "Target progress",
    "None", "PENDING_APPROVAL", "ABOVE_MATRIX", "BELOW_FLOOR", "NO_HEAD_LIMIT", "PRINCIPAL", "MANAGER",
]
ENGLISH_RE = re.compile(r"\b(" + "|".join(ENGLISH_WORDS) + r")\b")

# Terms the owner replaced (26 Oct 2026): "Kepala distributor" -> "Manajer", "grade" -> "klasifikasi".
REPLACED_TERMS_RE = re.compile(r"\b([Kk]epala distributor|[Gg]rade)\b")


def visible_text(page: str) -> str:
    page = re.sub(r"<(script|style)\b.*?</\1>", " ", page, flags=re.S)
    page = re.sub(r'(placeholder|aria-label)="([^"]*)"', r"> \2 <", page)      # these are read by users too
    text = re.sub(r"<[^>]+>", " ", page)
    return html.unescape(text)


def db_messages():
    found = set()
    for sql in sorted((ROOT / "db").glob("0*.sql")):
        for m in re.finditer(r"RAISE EXCEPTION '((?:[^']|'')*)'", sql.read_text()):
            found.add(m.group(1).replace("''", "'"))
    return sorted(found)


@pytest.mark.parametrize("message", db_messages())
def test_every_database_message_has_a_translation(message):
    sample = message.replace("%", "X")
    assert i18n.translate_db_message(sample), f"No Indonesian translation for: {message}"


def test_numbers_use_indonesian_format():
    assert i18n.rupiah(1234567) == "Rp 1.234.567"
    assert i18n.pct(16.17) == "16,2%"
    assert i18n.pct(1234.5) == "1.234,5%"
    from datetime import date
    assert i18n.tanggal(date(2026, 10, 26)) == "26 Okt 2026"


def test_every_screen_is_in_bahasa_indonesia():
    rep = client_as("rep1@demo.kps")
    pending = new_order(rep, JAYA, [("CAB-2D-01", 2, 3)])
    approved = new_order(rep, JAYA, [("CAB-2D-01", 1)])
    floor = new_order(rep, SENTOSA, [("TBL-DIN-01", 1)])
    rep.post(f"/orders/{approved}/confirm")
    rep.post("/orders/new", data={"customer_id": JAYA, "sku_0": "CAB-2D-01", "qty_0": "abc"})  # leaves an error message

    pages = {
        "rep1@demo.kps": ["/", "/orders", "/orders?status=PENDING_APPROVAL", "/orders/new", "/stores", "/stores/new",
                          "/catalog", f"/orders/{pending}", f"/orders/{approved}"],
        "head1@demo.kps": ["/", "/orders", "/approvals", f"/orders/{pending}", f"/orders/{floor}", "/stores/new"],
        "owner@demo.kps": ["/", "/orders", "/approvals", f"/orders/{floor}", "/catalog", "/stores"],
    }
    problems = []
    for email, paths in pages.items():
        c = client_as(email)
        for path in paths:
            text = visible_text(c.get(path).text)
            for hit in sorted(set(m.group(0) for m in ENGLISH_RE.finditer(text))):
                problems.append(f"{email} {path}: '{hit}'")
            for hit in sorted(set(m.group(0) for m in REPLACED_TERMS_RE.finditer(text))):
                problems.append(f"{email} {path}: old term '{hit}'")
    login = visible_text(client_as("rep1@demo.kps").get("/login").text)
    problems += [f"/login: '{m.group(0)}'" for m in ENGLISH_RE.finditer(login)]
    assert not problems, "English on screen:\n" + "\n".join(problems)


def test_routing_and_error_messages_are_in_bahasa():
    rep = client_as("rep1@demo.kps")
    r = rep.post("/orders/new", data={"customer_id": JAYA, "sku_0": "CAB-2D-01", "qty_0": 2, "extra_0": "3"},
                 follow_redirects=True)
    assert "dikirim ke manajer" in r.text
    r = rep.post("/orders/new", data={"customer_id": JAYA, "sku_0": "CAB-2D-01", "qty_0": "dua"}, follow_redirects=True)
    assert "harus berupa angka" in r.text
    r = rep.post("/orders/new", data={"customer_id": JAYA, "sku_0": "CAB-2D-01", "qty_0": 1, "extra_0": "2,5"},
                 follow_redirects=True)
    assert "dikirim ke manajer" in r.text                       # decimal comma accepted
