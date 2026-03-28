"""Date/time formatters and timezone helpers."""

from datetime import datetime, timedelta, timezone

_MSK = timezone(timedelta(hours=3))


def _fmt_msk(dt_val):
    """Format naive-UTC datetime as Moscow time string."""
    if not isinstance(dt_val, datetime):
        return dt_val
    utc = dt_val.replace(tzinfo=timezone.utc)
    msk = utc.astimezone(_MSK)
    return msk.strftime("%d.%m.%Y %H:%M")
