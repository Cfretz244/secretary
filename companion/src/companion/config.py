import os

CHAT_DB_PATH = os.environ.get(
    "CHAT_DB_PATH", os.path.expanduser("~/Library/Messages/chat.db")
)
AUTH_TOKEN = os.environ.get("COMPANION_AUTH_TOKEN")
if not AUTH_TOKEN:
    raise RuntimeError("COMPANION_AUTH_TOKEN environment variable is required")
PORT = int(os.environ.get("COMPANION_PORT", "8741"))
