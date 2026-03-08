from fastapi import APIRouter, Depends, Query

from ..auth import require_auth
from ..db import apple_date_to_iso, get_db
from ..message_parser import extract_text
from ..models import DataResponse, Message

router = APIRouter(dependencies=[Depends(require_auth)])


@router.get("/conversations/{chat_id}/messages")
def get_messages(
    chat_id: int,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    before: str | None = Query(None),
    after: str | None = Query(None),
) -> DataResponse:
    with get_db() as conn:
        query = """
            SELECT
                m.ROWID AS message_id,
                m.guid,
                m.text,
                m.attributedBody,
                m.is_from_me,
                m.date,
                m.service,
                COALESCE(h.id, '') AS sender
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ?
        """
        params: list = [chat_id]

        if after:
            query += " AND m.date > ? "
            params.append(_iso_to_apple_ns(after))

        if before:
            query += " AND m.date < ? "
            params.append(_iso_to_apple_ns(before))

        query += " ORDER BY m.date DESC LIMIT ? OFFSET ?"
        params.extend([limit, offset])

        rows = conn.execute(query, params).fetchall()

        messages = [_row_to_message(row) for row in rows]

    return DataResponse(data=[m.model_dump() for m in messages])


@router.get("/messages/search")
def search_messages(
    query: str = Query(..., min_length=1),
    limit: int = Query(20, ge=1, le=100),
    conversation_id: int | None = Query(None),
) -> DataResponse:
    with get_db() as conn:
        sql = """
            SELECT
                m.ROWID AS message_id,
                m.guid,
                m.text,
                m.attributedBody,
                m.is_from_me,
                m.date,
                m.service,
                COALESCE(h.id, '') AS sender,
                cmj.chat_id
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE m.text LIKE ?
        """
        params: list = [f"%{query}%"]

        if conversation_id is not None:
            sql += " AND cmj.chat_id = ?"
            params.append(conversation_id)

        sql += " ORDER BY m.date DESC LIMIT ?"
        params.append(limit)

        rows = conn.execute(sql, params).fetchall()

        results = []
        for row in rows:
            msg = _row_to_message(row)
            results.append(
                {
                    **msg.model_dump(),
                    "chat_id": row["chat_id"],
                }
            )

    return DataResponse(data=results)


def _row_to_message(row) -> Message:
    return Message(
        message_id=row["message_id"],
        guid=row["guid"] or "",
        text=extract_text(dict(row)),
        is_from_me=bool(row["is_from_me"]),
        date=apple_date_to_iso(row["date"]),
        sender=row["sender"] if not row["is_from_me"] else "me",
        service=row["service"] or "",
    )


_APPLE_EPOCH_OFFSET = 978307200


def _iso_to_apple_ns(iso_date: str) -> int:
    """Convert ISO date string to Apple nanosecond timestamp."""
    from datetime import datetime, timezone

    dt = datetime.fromisoformat(iso_date)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    unix_ts = dt.timestamp()
    return int((unix_ts - _APPLE_EPOCH_OFFSET) * 1_000_000_000)
