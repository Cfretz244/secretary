from fastapi import APIRouter

from ..db import get_db
from ..models import HealthResponse

router = APIRouter()


@router.get("/health")
def health() -> HealthResponse:
    try:
        with get_db() as conn:
            row = conn.execute("SELECT COUNT(*) AS cnt FROM message").fetchone()
            count = row["cnt"] if row else 0
    except Exception:
        count = 0
    return HealthResponse(message_count=count)
