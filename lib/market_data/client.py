"""
lib.market_data.client – Abstract market data interface with concrete adapters.

Add Bloomberg / Refinitiv / internal REST adapters by subclassing
MarketDataClient and registering them with the factory.

Usage (CSV adapter for dev/testing):
    from lib.market_data.client import get_market_data_client
    client = get_market_data_client()
    prices = client.get_prices("AAPL", date(2026, 1, 1), date(2026, 9, 22))
"""

import csv
import io
from abc import ABC, abstractmethod
from datetime import date
from dataclasses import dataclass

from lib.config.settings import get_settings
from lib.logging.structured import get_logger

log = get_logger(__name__)


@dataclass
class PriceBar:
    symbol: str
    as_of_date: date
    open: float
    high: float
    low: float
    close: float
    volume: float


class MarketDataClient(ABC):
    """Abstract base class for all market data sources."""

    @abstractmethod
    def get_price(self, symbol: str, as_of_date: date) -> PriceBar | None:
        """Return a single price bar for symbol on as_of_date, or None if unavailable."""

    @abstractmethod
    def get_prices(self, symbol: str, start: date, end: date) -> list[PriceBar]:
        """Return a list of daily price bars for symbol in [start, end] inclusive."""

    def get_latest_price(self, symbol: str) -> PriceBar | None:
        """Return the most recent price bar for symbol."""
        from lib.calendar.trading_calendar import prev_business_day
        return self.get_price(symbol, prev_business_day(date.today()))


class CsvMarketDataClient(MarketDataClient):
    """
    Simple CSV-backed client for development and unit testing.
    Reads from Azure Blob Storage or a local file path.

    CSV format: symbol,date,open,high,low,close,volume
    """

    def __init__(self, csv_content: str = "") -> None:
        self._bars: dict[tuple[str, date], PriceBar] = {}
        if csv_content:
            self._load(csv_content)

    def _load(self, content: str) -> None:
        reader = csv.DictReader(io.StringIO(content))
        for row in reader:
            bar = PriceBar(
                symbol=row["symbol"].upper(),
                as_of_date=date.fromisoformat(row["date"]),
                open=float(row["open"]),
                high=float(row["high"]),
                low=float(row["low"]),
                close=float(row["close"]),
                volume=float(row["volume"]),
            )
            self._bars[(bar.symbol, bar.as_of_date)] = bar

    def get_price(self, symbol: str, as_of_date: date) -> PriceBar | None:
        return self._bars.get((symbol.upper(), as_of_date))

    def get_prices(self, symbol: str, start: date, end: date) -> list[PriceBar]:
        sym = symbol.upper()
        return sorted(
            (b for (s, d), b in self._bars.items() if s == sym and start <= d <= end),
            key=lambda b: b.as_of_date,
        )


class RestMarketDataClient(MarketDataClient):
    """
    Placeholder for a REST-based internal market data service.
    Replace the base URL and auth with your internal service details.
    """

    def __init__(self, base_url: str, api_key: str) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key

    def get_price(self, symbol: str, as_of_date: date) -> PriceBar | None:
        raise NotImplementedError("Implement REST call to your market data service")

    def get_prices(self, symbol: str, start: date, end: date) -> list[PriceBar]:
        raise NotImplementedError("Implement REST call to your market data service")


def get_market_data_client() -> MarketDataClient:
    """
    Factory that returns the appropriate market data client for the environment.
    Configure via EQTECH_MARKET_DATA_ADAPTER env var: 'csv' | 'rest'
    """
    settings = get_settings()
    adapter = getattr(settings, "market_data_adapter", "csv")
    if adapter == "rest":
        base_url = getattr(settings, "market_data_url", "")
        api_key = getattr(settings, "market_data_api_key", "")
        log.info("Using REST market data client", base_url=base_url)
        return RestMarketDataClient(base_url=base_url, api_key=api_key)
    log.debug("Using CSV market data client (dev/test mode)")
    return CsvMarketDataClient()
