from fastapi import APIRouter, Depends, Query

from ..auth import require_auth
from ..db import apple_date_to_iso, get_db
from ..models import Conversation, DataResponse

router = APIRouter(dependencies=[Depends(require_auth)])


@router.get("/conversations")
def list_conversations(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    since: str | None = Query(None),
) -> DataResponse:
    with get_db() as conn:
        # Build query for conversations with participant info
        query = """
            SELECT
                c.ROWID AS chat_id,
                c.guid,
                c.chat_identifier,
                c.display_name,
                c.service_name,
                c.style AS chat_style,
                (
                    SELECT MAX(m.date)
                    FROM message m
                    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                    WHERE cmj.chat_id = c.ROWID
                ) AS last_message_date,
                (
                    SELECT COUNT(*)
                    FROM chat_message_join cmj
                    WHERE cmj.chat_id = c.ROWID
                ) AS message_count
            FROM chat c
        """
        params: list = []

        if since:
            query += """
                HAVING last_message_date IS NOT NULL
            """

        query += " ORDER BY last_message_date DESC LIMIT ? OFFSET ?"
        params.extend([limit, offset])

        rows = conn.execute(query, params).fetchall()

        conversations: list[dict] = []
        for row in rows:
            chat_id = row["chat_id"]

            # Get participants
            participants = _get_participants(conn, chat_id)

            conversations.append(
                Conversation(
                    chat_id=chat_id,
                    guid=row["guid"] or "",
                    chat_identifier=row["chat_identifier"] or "",
                    display_name=row["display_name"] or "",
                    service_name=row["service_name"] or "",
                    is_group=row["chat_style"] == 43,  # 43 = group chat
                    participants=participants,
                    last_message_date=apple_date_to_iso(row["last_message_date"]),
                    message_count=row["message_count"] or 0,
                ).model_dump()
            )

    return DataResponse(data=conversations)


@router.get("/conversations/{chat_id}")
def get_conversation(chat_id: int) -> DataResponse:
    with get_db() as conn:
        row = conn.execute(
            """
            SELECT
                c.ROWID AS chat_id,
                c.guid,
                c.chat_identifier,
                c.display_name,
                c.service_name,
                c.style AS chat_style,
                (
                    SELECT MAX(m.date)
                    FROM message m
                    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                    WHERE cmj.chat_id = c.ROWID
                ) AS last_message_date,
                (
                    SELECT COUNT(*)
                    FROM chat_message_join cmj
                    WHERE cmj.chat_id = c.ROWID
                ) AS message_count
            FROM chat c
            WHERE c.ROWID = ?
            """,
            [chat_id],
        ).fetchone()

        if not row:
            return DataResponse(ok=False, error=f"Conversation {chat_id} not found")

        participants = _get_participants(conn, chat_id)

        conv = Conversation(
            chat_id=row["chat_id"],
            guid=row["guid"] or "",
            chat_identifier=row["chat_identifier"] or "",
            display_name=row["display_name"] or "",
            service_name=row["service_name"] or "",
            is_group=row["chat_style"] == 43,
            participants=participants,
            last_message_date=apple_date_to_iso(row["last_message_date"]),
            message_count=row["message_count"] or 0,
        )

    return DataResponse(data=conv.model_dump())


def _get_participants(conn, chat_id: int) -> list[str]:
    """Get participant identifiers for a chat."""
    rows = conn.execute(
        """
        SELECT h.id
        FROM handle h
        JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
        WHERE chj.chat_id = ?
        """,
        [chat_id],
    ).fetchall()
    return [r["id"] for r in rows]
