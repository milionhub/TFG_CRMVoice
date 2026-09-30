"""JWT propios de CRMVoice y hash de contraseñas (sin dependencias de FastAPI ni de la BD)."""
from datetime import datetime, timedelta

from jose import JWTError, jwt
from passlib.context import CryptContext

import config

pwd_context = CryptContext(
    schemes=["bcrypt"],
    deprecated="auto"
)


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def create_access_token(data: dict):
    to_encode = data.copy()
    expire = datetime.utcnow() + timedelta(minutes=config.access_token_expire_minutes())
    to_encode.update({"exp": expire})

    return jwt.encode(to_encode, config.secret_key(), algorithm=config.jwt_algorithm())


def verify_token(token: str):
    try:
        return jwt.decode(token, config.secret_key(), algorithms=[config.jwt_algorithm()])
    except JWTError:
        return None
