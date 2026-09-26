"""
lib.portfolio.metrics – Core portfolio analytics for an asset management firm.

These functions operate on plain Python data structures so they can be called
from both Airflow DAG tasks (KubernetesExecutor pods) and FastAPI handlers
without importing heavy optional dependencies.

Usage:
    from lib.portfolio.metrics import compute_returns, compute_volatility
    rets = compute_returns([100, 101, 99, 103])
    vol  = compute_volatility(rets)
"""

import math
from dataclasses import dataclass, field


@dataclass
class PortfolioSummary:
    portfolio_id: str
    total_market_value: float
    total_cost_basis: float
    unrealised_pnl: float
    unrealised_pnl_pct: float
    positions: list[dict] = field(default_factory=list)


def compute_returns(prices: list[float]) -> list[float]:
    """
    Compute simple period-over-period returns.
    Returns a list of length len(prices) - 1.
    """
    if len(prices) < 2:
        return []
    return [(prices[i] - prices[i - 1]) / prices[i - 1] for i in range(1, len(prices))]


def compute_log_returns(prices: list[float]) -> list[float]:
    """Compute continuously compounded (log) returns."""
    if len(prices) < 2:
        return []
    return [math.log(prices[i] / prices[i - 1]) for i in range(1, len(prices))]


def compute_volatility(returns: list[float], annualise: bool = True) -> float:
    """
    Compute the standard deviation of returns.
    Annualises by multiplying by sqrt(252) (US trading days) when annualise=True.
    """
    n = len(returns)
    if n < 2:
        return 0.0
    mean = sum(returns) / n
    variance = sum((r - mean) ** 2 for r in returns) / (n - 1)
    vol = math.sqrt(variance)
    return vol * math.sqrt(252) if annualise else vol


def compute_sharpe_ratio(returns: list[float], risk_free_rate: float = 0.05) -> float:
    """
    Compute the annualised Sharpe ratio.
    risk_free_rate: annualised risk-free rate (default 5%).
    """
    n = len(returns)
    if n < 2:
        return 0.0
    daily_rf = risk_free_rate / 252
    excess = [r - daily_rf for r in returns]
    mean_excess = sum(excess) / n
    vol = compute_volatility(returns, annualise=False)
    if vol == 0:
        return 0.0
    return (mean_excess / vol) * math.sqrt(252)


def compute_max_drawdown(prices: list[float]) -> float:
    """
    Compute the maximum drawdown as a fraction (e.g. -0.15 means -15%).
    """
    if not prices:
        return 0.0
    peak = prices[0]
    max_dd = 0.0
    for p in prices:
        if p > peak:
            peak = p
        dd = (p - peak) / peak
        if dd < max_dd:
            max_dd = dd
    return max_dd


def compute_var(returns: list[float], confidence: float = 0.95) -> float:
    """
    Compute historical Value at Risk at the given confidence level.
    Returns the loss (negative number) at the confidence-th percentile.
    """
    if not returns:
        return 0.0
    sorted_returns = sorted(returns)
    index = int((1 - confidence) * len(sorted_returns))
    return sorted_returns[index]


def summarise_positions(positions: list[dict]) -> PortfolioSummary:
    """
    Aggregate a list of position dicts into a PortfolioSummary.
    Each dict must have: portfolio_id, symbol, quantity, cost_basis, market_price (optional).
    """
    if not positions:
        raise ValueError("positions must be non-empty")

    portfolio_id = positions[0]["portfolio_id"]
    total_mv = 0.0
    total_cost = 0.0
    enriched = []

    for p in positions:
        qty = float(p["quantity"])
        cost = float(p["cost_basis"])
        mp = float(p.get("market_price") or cost)  # fall back to cost if no market price
        mv = qty * mp
        pnl = qty * (mp - cost)
        total_mv += mv
        total_cost += qty * cost
        enriched.append({
            **p,
            "market_value": round(mv, 2),
            "unrealised_pnl": round(pnl, 2),
        })

    pnl = total_mv - total_cost
    return PortfolioSummary(
        portfolio_id=portfolio_id,
        total_market_value=round(total_mv, 2),
        total_cost_basis=round(total_cost, 2),
        unrealised_pnl=round(pnl, 2),
        unrealised_pnl_pct=round(pnl / total_cost, 6) if total_cost else 0.0,
        positions=enriched,
    )
