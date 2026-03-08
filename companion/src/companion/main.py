from fastapi import FastAPI

from .routers import conversations, health, messages

app = FastAPI(title="Messages Companion", version="1.0.0")

app.include_router(health.router)
app.include_router(conversations.router)
app.include_router(messages.router)
