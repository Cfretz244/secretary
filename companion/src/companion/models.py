from pydantic import BaseModel


class Conversation(BaseModel):
    chat_id: int
    guid: str
    chat_identifier: str
    display_name: str
    service_name: str
    is_group: bool
    participants: list[str]
    last_message_date: str
    message_count: int


class Message(BaseModel):
    message_id: int
    guid: str
    text: str
    is_from_me: bool
    date: str
    sender: str
    service: str


class HealthResponse(BaseModel):
    ok: bool = True
    version: str = "1.0.0"
    message_count: int = 0


class DataResponse(BaseModel):
    ok: bool = True
    data: list | dict | None = None
    error: str | None = None
