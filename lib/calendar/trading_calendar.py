"""
lib.calendar.trading_calendar – US equity market business-day utilities.

Covers NYSE/NASDAQ holidays for 2024-2026.  For a production-grade solution
replace the hard-coded set with pandas_market_calendars:

    import pandas_market_calendars as mcal
    nyse = mcal.get_calendar("NYSE")

Usage:
    from lib.calendar.trading_calendar import prev_business_day, business_days_between
    from datetime import date

    yesterday = prev_business_day(date.today())
    days = list(business_days_between(date(2026, 1, 1), date(2026, 1, 31)))
"""

from datetime import date, timedelta
from typing import Iterator

# NYSE/NASDAQ market holidays 2024-2026 (early-close days are NOT included)
_HOLIDAYS: frozenset[date] = frozenset({
    # 2024
    date(2024, 1, 1),  date(2024, 1, 15),  date(2024, 2, 19),
    date(2024, 3, 29), date(2024, 5, 27),  date(2024, 6, 19),
    date(2024, 7, 4),  date(2024, 9, 2),   date(2024, 11, 28),
    date(2024, 12, 25),
    # 2025
    date(2025, 1, 1),  date(2025, 1, 20),  date(2025, 2, 17),
    date(2025, 4, 18), date(2025, 5, 26),  date(2025, 6, 19),
    date(2025, 7, 4),  date(2025, 9, 1),   date(2025, 11, 27),
    date(2025, 12, 25),
    # 2026
    date(2026, 1, 1),  date(2026, 1, 19),  date(2026, 2, 16),
    date(2026, 4, 3),  date(2026, 5, 25),  date(2026, 6, 19),
    date(2026, 7, 3),  date(2026, 9, 7),   date(2026, 11, 26),
    date(2026, 12, 25),
})


def is_business_day(d: date) -> bool:
    """Return True if d is a weekday and not a US market holiday."""
    return d.weekday() < 5 and d not in _HOLIDAYS


def prev_business_day(d: date, n: int = 1) -> date:
    """Return the nth previous business day relative to d (exclusive of d)."""
    remaining = n
    current = d
    while remaining > 0:
        current -= timedelta(days=1)
        if is_business_day(current):
            remaining -= 1
    return current


def next_business_day(d: date, n: int = 1) -> date:
    """Return the nth next business day relative to d (exclusive of d)."""
    remaining = n
    current = d
    while remaining > 0:
        current += timedelta(days=1)
        if is_business_day(current):
            remaining -= 1
    return current


def add_business_days(d: date, n: int) -> date:
    """Add n business days to d. Negative n moves backwards."""
    if n == 0:
        return d
    direction = 1 if n > 0 else -1
    remaining = abs(n)
    current = d
    while remaining > 0:
        current += timedelta(days=direction)
        if is_business_day(current):
            remaining -= 1
    return current


def business_days_between(start: date, end: date) -> Iterator[date]:
    """Yield every business day in the closed interval [start, end]."""
    current = start
    while current <= end:
        if is_business_day(current):
            yield current
        current += timedelta(days=1)


def count_business_days(start: date, end: date) -> int:
    """Count business days in [start, end] inclusive."""
    return sum(1 for _ in business_days_between(start, end))


def last_business_day_of_month(year: int, month: int) -> date:
    """Return the last business day of the given month."""
    if month == 12:
        first_of_next = date(year + 1, 1, 1)
    else:
        first_of_next = date(year, month + 1, 1)
    return prev_business_day(first_of_next)
