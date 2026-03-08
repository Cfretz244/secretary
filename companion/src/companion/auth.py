from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .config import AUTH_TOKEN

_scheme = HTTPBearer()


async def require_auth(
    credentials: HTTPAuthorizationCredentials = Depends(_scheme),
) -> str:
    if credentials.credentials != AUTH_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token"
        )
    return credentials.credentials
