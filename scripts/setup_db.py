"""Create or update the database schema, and optionally load demo data.

Usage:
    DATABASE_URL=postgresql://user:pass@host/db python scripts/setup_db.py           # schema only
    DATABASE_URL=...                             python scripts/setup_db.py --demo    # schema + demo data
    DATABASE_URL=...                             python scripts/setup_db.py --reset --demo  # DROP and rebuild (never in production)
"""
import os
import sys
from pathlib import Path

import psycopg
from passlib.hash import bcrypt

ROOT = Path(__file__).resolve().parents[1]
URL = os.environ.get("DATABASE_URL", "postgresql://pg@localhost:5432/kps")

DEMO_PASSWORD = "demo1234"


def run_file(conn, path):
    conn.execute(path.read_text())


def main():
    args = set(sys.argv[1:])
    with psycopg.connect(URL, autocommit=True) as conn:
        if "--reset" in args:
            conn.execute("DROP SCHEMA IF EXISTS core CASCADE")
        exists = conn.execute("SELECT to_regclass('core.entity') IS NOT NULL").fetchone()[0]
        if not exists:
            run_file(conn, ROOT / "db" / "001_core_schema.sql")
        for path in sorted((ROOT / "db").glob("0*.sql")):
            if path.name != "001_core_schema.sql":
                run_file(conn, path)          # later files are safe to re-run
        print("Schema ready.")
        if "--demo" in args:
            load_demo(conn)
            print(f"Demo data loaded. All demo users use password: {DEMO_PASSWORD}")


def load_demo(conn):
    """Example data only. Discount percentages here are NOT the company's real rules."""
    h = bcrypt.hash(DEMO_PASSWORD)
    conn.execute("SET search_path = core, public")
    if conn.execute("SELECT COUNT(*) FROM entity").fetchone()[0]:
        print("Demo skipped: data already present.")
        return
    conn.execute("""
        INSERT INTO entity (code, legal_name, entity_role, margin_floor_pct) VALUES
          ('PRN','PT Principal (demo)','PRINCIPAL',NULL),
          ('DST01','PT Distributor Satu (demo)','DISTRIBUTOR',10),
          ('DST02','PT Distributor Dua (demo)','DISTRIBUTOR',10);
        INSERT INTO territory (entity_id, code, name) VALUES
          (2,'D01-JKT','Jakarta Barat'),(2,'D01-TNG','Tangerang'),(3,'D02-SBY','Surabaya');
    """)
    conn.execute("""
        INSERT INTO app_user (entity_id, full_name, role, reports_to, email, password_hash) VALUES
          (1,'Pemilik','OWNER',NULL,'owner@demo.kps',%(h)s),
          (1,'Direktur Penjualan','PRN_SALES_DIR',1,'salesdir@demo.kps',%(h)s),
          (2,'Budi (Manajer D01)','DST_HEAD',NULL,'head1@demo.kps',%(h)s),
          (2,'Sari (Sales D01)','SALES_REP',3,'rep1@demo.kps',%(h)s),
          (3,'Andi (Manajer D02)','DST_HEAD',NULL,'head2@demo.kps',%(h)s),
          (3,'Dewi (Sales D02)','SALES_REP',5,'rep2@demo.kps',%(h)s);
    """, {"h": h})
    conn.execute("""
        INSERT INTO product (sku, name, category, material, status) VALUES
          ('CAB-2D-01','Lemari 2 pintu walnut','LEMARI','Particle board','ACTIVE'),
          ('CAB-3D-01','Lemari 3 pintu putih','LEMARI','MDF','ACTIVE'),
          ('TBL-DIN-01','Meja makan 6 kursi','MEJA MAKAN','Kayu solid','ACTIVE'),
          ('SHF-IP-01','Rak pipa besi 5 susun','RAK','Pipa besi','SLOW'),
          ('DSK-ST-01','Meja belajar','MEJA BELAJAR','Particle board','CLEARANCE');
        INSERT INTO price_list (sku, list_price, valid) VALUES
          ('CAB-2D-01',1250000,'[2026-01-01,)'),('CAB-3D-01',1850000,'[2026-01-01,)'),
          ('TBL-DIN-01',4200000,'[2026-01-01,)'),('SHF-IP-01',950000,'[2026-01-01,)'),
          ('DSK-ST-01',780000,'[2026-01-01,)');
        -- principal -> distributor: 50%+3%+5% off the national price list (owner's example)
        INSERT INTO distributor_discount (entity_id, disc_pct, valid, steps) VALUES
          (2, 0, '[2026-01-01,)', '{50,3,5}'), (3, 0, '[2026-01-01,)', '{50,3,5}');
        INSERT INTO commission_plan VALUES (2,'REVENUE',3,'[2026-01-01,)'),(3,'REVENUE',3,'[2026-01-01,)');
        -- distributor -> store: standard 40%+5%; grade PLUS gets another +3% (owner's example; grade names are demo)
        INSERT INTO store_grade (entity_id, grade_code, name) VALUES
          (2,'STD','Standar'),(2,'PLUS','Standar +3%'),(3,'STD','Standar'),(3,'PLUS','Standar +3%');
        INSERT INTO grade_discount (entity_id, grade_code, category, steps, valid) VALUES
          (2,'STD',NULL,'{40,5}','[2026-01-01,)'),(2,'PLUS',NULL,'{40,5,3}','[2026-01-01,)'),
          (3,'STD',NULL,'{40,5}','[2026-01-01,)'),(3,'PLUS',NULL,'{40,5,3}','[2026-01-01,)'),
          -- example of a category override: slow-moving shelves get an extra 5% for standard stores in DST01
          (2,'STD','RAK','{40,5,5}','[2026-01-01,)');
        INSERT INTO customer (entity_id, territory_id, rep_id, store_name, owner_name, customer_class, grade_code, whatsapp_no, wa_opt_in_at, city) VALUES
          (2,1,4,'Toko Mebel Jaya','Pak Hendra','SMALL','STD','6281100000001',now(),'Jakarta Barat'),
          (2,1,4,'Sentosa Furniture','Bu Lina','BIG','PLUS','6281100000002',now(),'Jakarta Barat'),
          (2,2,4,'Rumah Interior Tangerang','Pak Joko','SMALL','STD','6281100000003',NULL,'Tangerang'),
          (3,3,6,'Surya Mebel','Pak Agus','BIG','STD','6281100000004',now(),'Surabaya');
        INSERT INTO warehouse (entity_id, name) VALUES (2,'Gudang D01'),(3,'Gudang D02');
        INSERT INTO stock (warehouse_id, sku, on_hand, reserved) VALUES
          (1,'CAB-2D-01',120,0),(1,'CAB-3D-01',60,0),(1,'TBL-DIN-01',15,0),(1,'SHF-IP-01',40,0),(1,'DSK-ST-01',25,0),
          (2,'CAB-2D-01',80,0),(2,'TBL-DIN-01',10,0);
        INSERT INTO sales_target (entity_id, rep_id, period, revenue_target) VALUES
          (2,NULL,date_trunc('month',CURRENT_DATE)::date,250000000),
          (2,4,date_trunc('month',CURRENT_DATE)::date,150000000),
          (3,NULL,date_trunc('month',CURRENT_DATE)::date,200000000);
        INSERT INTO invoice (entity_id, invoice_no, customer_id, invoice_date, due_date, total_amount) VALUES
          (2,'D01-INV-00001',1,CURRENT_DATE-50,CURRENT_DATE-20,6200000);
        -- demo values only (real floors and head limits come from the VB data):
        -- dining tables need 15% margin, shelves 5%, everything else the distributor default (10%)
        INSERT INTO item_margin_floor (sku, category, floor_pct, valid) VALUES
          ('TBL-DIN-01', NULL, 15, '[2026-01-01,)'), (NULL, 'RAK', 5, '[2026-01-01,)');
        -- head may approve, beyond the store's standard price: 2-door cabinet up to 5% extra;
        -- 3-door cabinet down to Rp 1,000,000 a unit; dining table up to 3% extra; shelves up to 5% extra;
        -- the study desk has no head limit
        INSERT INTO item_head_limit (sku, category, min_unit_price, max_disc_pct, valid) VALUES
          ('CAB-2D-01', NULL, NULL, 5, '[2026-01-01,)'),
          ('CAB-3D-01', NULL, 1000000, NULL, '[2026-01-01,)'),
          ('TBL-DIN-01', NULL, NULL, 3, '[2026-01-01,)'),
          (NULL, 'RAK', NULL, 5, '[2026-01-01,)');
    """)


if __name__ == "__main__":
    main()
