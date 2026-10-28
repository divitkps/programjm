"""Bahasa Indonesia for everything a user sees.

The database raises its messages in English (they are also read by developers and in logs).
Every one of them is translated here before it reaches a screen. tests/test_bahasa.py fails
if a message is added to the database without a translation below.
"""
import re
from datetime import date, datetime
from decimal import Decimal

# ---------------------------------------------------------------- words shown on screens
STATUS = {
    "DRAFT": "Draf",
    "PENDING_APPROVAL": "Menunggu persetujuan",
    "APPROVED": "Disetujui",
    "CONFIRMED": "Dikonfirmasi",
    "DELIVERED": "Terkirim",
    "REJECTED": "Ditolak",
    "CANCELLED": "Dibatalkan",
}
REQUEST_STATUS = {
    "OPEN": "Menunggu",
    "APPROVED": "Disetujui",
    "REJECTED": "Ditolak",
    "PASSED_UP": "Diteruskan ke prinsipal",
    "EXPIRED": "Kedaluwarsa",
    "WITHDRAWN": "Ditarik",
}
LEVEL = {
    "REP": "Sales (sesuai aturan)",
    "MANAGER": "Manajer",
    "PRINCIPAL": "Prinsipal",
}
REASON = {
    "ABOVE_MATRIX": "di bawah harga standar",
    "BELOW_FLOOR": "margin barang di bawah batas",
    "ABOVE_HEAD_LIMIT": "melebihi batas manajer",
    "NO_HEAD_LIMIT": "barang belum punya batas manajer",
    "PASSED_UP": "diteruskan oleh manajer",
    "SUPPORT_NEEDED": "perlu diskon dukungan",
    "OWN_ORDER": "pesanan sendiri",
}
ORDER_TYPE = {"REGULAR": "Reguler", "PROJECT": "Proyek"}
PRODUCT_STATUS = {"ACTIVE": "Aktif", "SLOW": "Lambat laku", "CLEARANCE": "Cuci gudang", "DISCONTINUED": "Tidak diproduksi"}

MONTHS = ["Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"]


def rupiah(value) -> str:
    if value is None:
        return "–"
    return "Rp " + f"{Decimal(value):,.0f}".replace(",", ".")


def pct(value, digits=1) -> str:
    """16.17 -> '16,2%' (Indonesian decimal comma)."""
    if value is None:
        return "–"
    text = f"{Decimal(value):,.{digits}f}"
    return text.replace(",", "_").replace(".", ",").replace("_", ".") + "%"


def tanggal(value) -> str:
    if value is None:
        return "–"
    if isinstance(value, datetime):
        value = value.date()
    if isinstance(value, date):
        return f"{value.day} {MONTHS[value.month - 1]} {value.year}"
    return str(value)


def angka(value, digits=0) -> str:
    if value is None:
        return "–"
    text = f"{Decimal(value):,.{digits}f}"
    return text.replace(",", "_").replace(".", ",").replace("_", ".")


# ---------------------------------------------------------------- database messages
# (English pattern from the database, Indonesian message). Groups are inserted in order.
DB_MESSAGES = [
    (r"A (.+) order cannot be cancelled", "Pesanan berstatus {0} tidak dapat dibatalkan."),
    (r"A SKU on order (.+) has no valid list price", "Ada barang di pesanan {0} yang belum punya harga pricelist yang berlaku."),
    (r"A cancellation reason is required", "Alasan pembatalan wajib diisi."),
    (r"A short reason is required", "Alasan singkat wajib diisi."),
    (r"Approval request (.+) not found", "Permintaan persetujuan {0} tidak ditemukan."),
    (r"Discount step (.+) is not between 0 and 100", "Langkah diskon {0} harus di antara 0 dan 100."),
    (r"Grade (.+) has no standard discount for an item on order (.+)", "Klasifikasi {0} belum punya diskon standar untuk salah satu barang di pesanan {1}."),
    (r"No commission plan valid on (.+)", "Belum ada aturan komisi yang berlaku pada {0}."),
    (r"No distributor discount valid on (.+)", "Belum ada diskon distributor yang berlaku pada {0}."),
    (r"Not enough stock for (.+) \(needed (.+)\)", "Stok {0} tidak cukup (dibutuhkan {1})."),
    (r"Only approved orders can be confirmed", "Hanya pesanan yang sudah disetujui yang dapat dikonfirmasi."),
    (r"Only confirmed orders can be delivered", "Hanya pesanan yang sudah dikonfirmasi yang dapat dikirim."),
    (r"Only manager-level requests can be passed up", "Hanya permintaan di tingkat manajer yang dapat diteruskan ke prinsipal."),
    (r"Only orders with an expired approval can be re-priced", "Hanya pesanan dengan persetujuan kedaluwarsa yang dapat dihitung ulang."),
    (r"Order (.+) already waits for approval; decide or withdraw that request first",
     "Pesanan {0} masih menunggu persetujuan; putuskan atau tarik dulu permintaan tersebut."),
    (r"Store (.+) has no grade yet; set its grade before taking orders",
     "Toko {0} belum punya klasifikasi; tetapkan klasifikasinya sebelum menerima pesanan."),
    (r"The approval has expired \(older than (.+) days\); re-price the order first",
     "Persetujuan sudah kedaluwarsa (lebih dari {0} hari); hitung ulang harga pesanan terlebih dahulu."),
    (r"This request was already decided", "Permintaan ini sudah diputuskan."),
    (r"Unknown decision (.+)", "Keputusan tidak dikenal: {0}."),
    (r"You are not allowed to decide this request", "Anda tidak berwenang memutuskan permintaan ini."),
    (r"You entered this order, so someone else must decide it",
     "Anda yang memasukkan pesanan ini, jadi orang lain yang harus memutuskannya."),
    (r"Store (.+) is in another distributor's territory", "Toko {0} berada di wilayah distributor lain."),
    (r"Store has not opted in to WhatsApp messages", "Toko belum menyetujui menerima pesan WhatsApp."),
    (r"Journal (.+) not balanced.*", "Jurnal {0} tidak seimbang."),
    (r"Posted journals cannot be reopened; reverse them instead", "Jurnal yang sudah diposting tidak dapat dibuka kembali; buat jurnal balik."),
]
_COMPILED = [(re.compile(rf"^{p}$"), m) for p, m in DB_MESSAGES]

# Postgres's own errors, by SQLSTATE
SQLSTATE_MESSAGES = {
    "23503": "Data yang dipilih tidak cocok dengan data lain (misalnya klasifikasi atau wilayah milik distributor lain).",
    "23505": "Data ini sudah ada.",
    "23514": "Ada nilai yang tidak valid. Periksa kembali isian Anda.",
    "23P01": "Bertabrakan dengan aturan lain pada periode yang sama.",
    "23502": "Ada isian wajib yang masih kosong.",
    "22P02": "Format isian tidak valid. Gunakan angka untuk jumlah, diskon dan harga.",
    "22003": "Angka terlalu besar.",
}
FALLBACK = "Terjadi kesalahan saat menyimpan. Silakan coba lagi atau hubungi admin."


def translate_db_message(message: str) -> str | None:
    message = (message or "").strip()
    for pattern, indo in _COMPILED:
        m = pattern.match(message)
        if m:
            parts = [STATUS.get(g.upper().replace(" ", "_"), g) if g else g for g in m.groups()]
            return indo.format(*parts)
    return None


def db_error_id(exc) -> str:
    diag = getattr(exc, "diag", None)
    primary = getattr(diag, "message_primary", None) if diag else None
    sqlstate = getattr(diag, "sqlstate", None) if diag else None
    if primary:
        translated = translate_db_message(primary)
        if translated:
            return translated
    if sqlstate in SQLSTATE_MESSAGES:
        return SQLSTATE_MESSAGES[sqlstate]
    return FALLBACK


def install(env):
    """Register the Indonesian filters and word lists on a Jinja environment."""
    env.filters["rp"] = rupiah
    env.filters["pct"] = pct
    env.filters["tgl"] = tanggal
    env.filters["angka"] = angka
    env.globals.update(STATUS=STATUS, REQUEST_STATUS=REQUEST_STATUS, LEVEL=LEVEL, REASON=REASON,
                       ORDER_TYPE=ORDER_TYPE, PRODUCT_STATUS=PRODUCT_STATUS)
