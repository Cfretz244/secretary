import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone

from .config import CHAT_DB_PATH

# Apple Cocoa epoch: 2001-01-01 00:00:00 UTC
_APPLE_EPOCH_OFFSET = 978307200


def apple_date_to_iso(apple_ns: int | None) -> str:
    """Convert Apple nanosecond timestamp to ISO 8601 string."""
    if not apple_ns:
        return ""
    unix_ts = (apple_ns / 1_000_000_000) + _APPLE_EPOCH_OFFSET
    return datetime.fromtimestamp(unix_ts, tz=timezone.utc).isoformat()


@contextmanager
def get_db():
    """Yield a read-only connection to chat.db."""
    conn = sqlite3.connect(f"file:{CHAT_DB_PATH}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()
