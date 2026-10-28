"""Login, current user and data scope."""
from fastapi import HTTPException, Request
from passlib.hash import bcrypt

from .db import one_row

PRINCIPAL_ROLES = {"OWNER", "PRN_FINANCE", "PRN_SALES_DIR", "PRN_PRICING"}
DECIDER_ROLES = {"OWNER", "PRN_SALES_DIR", "DST_HEAD"}
SEES_MARGIN = PRINCIPAL_ROLES | {"DST_HEAD"}   # reps do not see the distributor's buying cost


def hash_password(plain: str) -> str:
    return bcrypt.hash(plain)


def check_login(email: str, password: str):
    user = one_row(
        "SELECT user_id, password_hash FROM app_user WHERE lower(email) = lower(%(e)s) AND active",
        {"e": email.strip()},
    )
    if user and user["password_hash"] and bcrypt.verify(password, user["password_hash"]):
        return user["user_id"]
    return None


class NotLoggedIn(Exception):
    pass


def current_user(request: Request) -> dict:
    uid = request.session.get("uid")
    if not uid:
        raise NotLoggedIn()
    user = one_row(
        """SELECT u.user_id, u.full_name, u.role, u.entity_id, e.code AS entity_code, e.legal_name
             FROM app_user u JOIN entity e USING (entity_id)
            WHERE u.user_id = %(u)s AND u.active""",
        {"u": uid},
    )
    if not user:
        request.session.clear()
        raise NotLoggedIn()
    user["is_principal"] = user["role"] in PRINCIPAL_ROLES
    user["sees_margin"] = user["role"] in SEES_MARGIN
    user["can_decide"] = user["role"] in DECIDER_ROLES
    return user


def entity_filter(user: dict, column: str = "entity_id") -> tuple[str, dict]:
    """SQL condition limiting rows to what this user may see."""
    if user["is_principal"]:
        return "TRUE", {}
    return f"{column} = %(scope_entity)s", {"scope_entity": user["entity_id"]}


def require_same_entity(user: dict, entity_id: int):
    if not user["is_principal"] and user["entity_id"] != entity_id:
        raise HTTPException(status_code=404)
