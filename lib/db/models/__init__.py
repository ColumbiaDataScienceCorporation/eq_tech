from lib.db.models.base import Base
from lib.db.models.portfolio import PortfolioPosition


def init_db() -> None:
    """Create all tables in the current environment's database. Safe to call repeatedly."""
    from lib.db.postgres import get_engine
    Base.metadata.create_all(bind=get_engine())


__all__ = ["Base", "PortfolioPosition", "init_db"]
