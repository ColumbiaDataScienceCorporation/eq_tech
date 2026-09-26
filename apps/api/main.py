from datetime import date

from fastapi import Depends, FastAPI, Request

from lib.auth.groups import get_request_email, get_request_user, require_groups
from lib.config.settings import get_settings
from lib.db.models import PortfolioPosition, init_db
from lib.db.postgres import get_db_session, health_check as pg_health
from lib.logging.structured import get_logger
from lib.portfolio.metrics import summarise_positions

log = get_logger(__name__)
settings = get_settings()

app = FastAPI(title="EQ Tech API", version="1.0.0")


@app.on_event("startup")
def startup() -> None:
    """Create DB tables on startup if they don't exist yet."""
    init_db()
    log.info("API started", environment=settings.environment.value)


@app.get("/healthz")
def health_check():
    """Liveness probe – unauthenticated."""
    return {"status": "healthy", "db": "ok" if pg_health() else "unreachable"}


@app.get("/api/v1/me")
def whoami(request: Request):
    """Returns the authenticated user's identity and group memberships."""
    return {
        "user":   get_request_user(request),
        "email":  get_request_email(request),
        "groups": request.headers.get("X-Auth-Request-Groups", "").split(","),
    }


@app.get("/api/v1/portfolio")
def get_portfolio(
    request: Request,
    portfolio_id: str = "P001",
    # Requires caller to be in the analysts OR admins Entra group
    _groups=require_groups(settings.analysts_group_id, settings.admins_group_id),
):
    """
    Returns live portfolio positions from PostgreSQL and computes a summary.
    Uses lib.db for DB access, lib.auth for group gate, lib.portfolio for analytics.
    """
    with get_db_session() as session:
        rows = (
            session.query(PortfolioPosition)
            .filter(
                PortfolioPosition.portfolio_id == portfolio_id,
                PortfolioPosition.as_of_date == date.today(),
            )
            .all()
        )

    if not rows:
        # Return synthetic data when the table is empty (demo / first run)
        positions = [
            {"portfolio_id": portfolio_id, "symbol": "AAPL", "quantity": 100,
             "cost_basis": 150.0, "market_price": 185.5},
            {"portfolio_id": portfolio_id, "symbol": "MSFT", "quantity": 50,
             "cost_basis": 300.0, "market_price": 415.2},
            {"portfolio_id": portfolio_id, "symbol": "GOOG", "quantity": 75,
             "cost_basis": 140.0, "market_price": 175.8},
        ]
    else:
        positions = [
            {
                "portfolio_id": r.portfolio_id,
                "symbol": r.symbol,
                "quantity": r.quantity,
                "cost_basis": r.cost_basis,
                "market_price": r.market_price,
            }
            for r in rows
        ]

    summary = summarise_positions(positions)
    log.info("Portfolio retrieved",
             user=get_request_user(request),
             portfolio_id=portfolio_id,
             num_positions=len(positions))
    return {
        "portfolio_id": summary.portfolio_id,
        "total_market_value": summary.total_market_value,
        "unrealised_pnl": summary.unrealised_pnl,
        "unrealised_pnl_pct": summary.unrealised_pnl_pct,
        "positions": summary.positions,
    }
