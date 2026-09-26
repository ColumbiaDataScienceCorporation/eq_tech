"""
lib.db.models.portfolio – ORM models for portfolio data.

These tables are created in the environment-specific PostgreSQL database
(airflow_dev / airflow_uat / airflow_prod).  Run `lib.db.models.init_db()`
once per environment to create tables, or use Alembic for migrations.
"""

from datetime import date, datetime

from sqlalchemy import Date, DateTime, Float, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column

from lib.db.models.base import Base


class PortfolioPosition(Base):
    """Current or historical position of a security in a portfolio."""

    __tablename__ = "portfolio_positions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    portfolio_id: Mapped[str] = mapped_column(String(50), nullable=False, index=True)
    symbol: Mapped[str] = mapped_column(String(20), nullable=False)
    quantity: Mapped[float] = mapped_column(Float, nullable=False)
    cost_basis: Mapped[float] = mapped_column(Float, nullable=False)
    market_price: Mapped[float | None] = mapped_column(Float, nullable=True)
    as_of_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.now(), onupdate=func.now()
    )

    @property
    def market_value(self) -> float | None:
        if self.market_price is not None:
            return self.quantity * self.market_price
        return None

    @property
    def unrealised_pnl(self) -> float | None:
        if self.market_price is not None:
            return self.quantity * (self.market_price - self.cost_basis)
        return None

    def __repr__(self) -> str:
        return f"<Position {self.portfolio_id} {self.symbol} qty={self.quantity}>"
