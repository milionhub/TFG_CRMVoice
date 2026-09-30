import re

from pydantic import BaseModel, field_validator

# Mismos mínimos que ya exige el formulario de registro del frontend
EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
MIN_PASSWORD_LENGTH = 6


class LoginRequest(BaseModel):
    email: str
    password: str


class RegisterRequest(BaseModel):
    nombre: str
    email: str
    password: str

    @field_validator("email")
    @classmethod
    def email_valido(cls, value: str) -> str:
        value = value.strip()
        if not EMAIL_PATTERN.match(value):
            raise ValueError("Email no válido")
        return value

    @field_validator("password")
    @classmethod
    def password_con_longitud_minima(cls, value: str) -> str:
        if len(value) < MIN_PASSWORD_LENGTH:
            raise ValueError(f"La contraseña debe tener al menos {MIN_PASSWORD_LENGTH} caracteres")
        return value
