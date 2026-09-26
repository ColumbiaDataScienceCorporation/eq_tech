"""
lib.auth.groups – AD group authorization helpers for FastAPI and Flask/Dash.

OAuth2 Proxy injects authenticated user's Entra ID group memberships into
every request as the X-Auth-Request-Groups header (comma-separated UUIDs).
These utilities parse that header and enforce group membership.

FastAPI usage:
    from lib.auth.groups import require_groups
    from lib.config.settings import get_settings

    @app.get("/api/v1/positions")
    def positions(groups=Depends(require_groups(get_settings().analysts_group_id))):
        ...

Flask/Dash usage:
    from lib.auth.groups import FlaskGroupAuth
    from lib.config.settings import get_settings

    s = get_settings()
    auth = FlaskGroupAuth(s.analysts_group_id, s.admins_group_id)
    app.server.before_request(auth.before_request)
"""

from fastapi import Depends, HTTPException, Request
from flask import request as flask_request, abort


def parse_groups(header_value: str) -> list[str]:
    """Split the X-Auth-Request-Groups header into a list of non-empty UUIDs."""
    return [g.strip() for g in header_value.split(",") if g.strip()]


def get_request_groups(request: Request) -> list[str]:
    """FastAPI dependency: return the caller's Entra group UUIDs."""
    return parse_groups(request.headers.get("X-Auth-Request-Groups", ""))


def get_request_user(request: Request) -> str:
    return request.headers.get("X-Auth-Request-User", "unknown")


def get_request_email(request: Request) -> str:
    return request.headers.get("X-Auth-Request-Email", "unknown")


def require_groups(*group_ids: str):
    """
    FastAPI dependency factory. Raises HTTP 403 unless the caller belongs to
    at least one of the supplied Entra group Object IDs.

    Usage:
        @app.get("/admin")
        def admin_view(groups=Depends(require_groups(ADMINS_GROUP_ID))):
            ...
    """
    def _dependency(request: Request) -> list[str]:
        user_groups = get_request_groups(request)
        if not any(gid in user_groups for gid in group_ids):
            raise HTTPException(
                status_code=403,
                detail=(
                    f"Access denied. User {get_request_user(request)!r} is not a "
                    f"member of any required group."
                ),
            )
        return user_groups

    return Depends(_dependency)


def user_has_any_group(request: Request, *group_ids: str) -> bool:
    """Return True if the caller belongs to at least one of the given groups."""
    user_groups = get_request_groups(request)
    return any(gid in user_groups for gid in group_ids)


class FlaskGroupAuth:
    """
    Flask/Dash request hook that enforces AD group membership before every
    non-exempt request.

    Example:
        s = get_settings()
        auth = FlaskGroupAuth(s.analysts_group_id, s.admins_group_id)
        app.server.before_request(auth.before_request)
    """

    def __init__(
        self,
        *required_group_ids: str,
        exempt_prefixes: tuple[str, ...] = ("/_dash", "/healthz", "/_reload-hash"),
    ) -> None:
        self.required_group_ids = required_group_ids
        self.exempt_prefixes = exempt_prefixes

    def before_request(self) -> None:
        if any(flask_request.path.startswith(p) for p in self.exempt_prefixes):
            return
        groups = parse_groups(flask_request.headers.get("X-Auth-Request-Groups", ""))
        if not any(gid in groups for gid in self.required_group_ids):
            abort(403)

    def current_user_groups(self) -> list[str]:
        return parse_groups(flask_request.headers.get("X-Auth-Request-Groups", ""))

    def current_user(self) -> str:
        return flask_request.headers.get("X-Auth-Request-User", "unknown")
