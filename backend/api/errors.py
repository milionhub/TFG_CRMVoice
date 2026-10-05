"""
Traducción ÚNICA de los errores de dominio a HTTP (H.2). Las rutas no
construyen respuestas de error: lanzan (o dejan pasar) estos errores.

    NotFound           -> 404 {"detail"}
    ValidationFailed   -> 422 {"detail", "issues"}
    Duplicate          -> 409 {"detail", "code", "existing_id", "issues"}
    Conflict           -> 409 {"detail", "code"}
    (+ los datos de `extra`: p. ej. "draft" o "transcript")
    Gone               -> 410 {"detail", "code"}
    ServiceUnavailable -> 503 {"detail", "code"}

Los mensajes son siempre los del dominio (en español y seguros): nunca el
texto de una excepción de OpenAI, de SQLite ni una traza.

Además, los 422 de validación de FastAPI (forma del cuerpo) conservan su
"detail" estándar y añaden "issues" con el mismo formato que los de dominio.
"""
from fastapi import FastAPI, Request
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from schemas.issues import issues_from_pydantic
from services.writes import (Conflict, Duplicate, Gone, NotFound, ServiceUnavailable, ValidationFailed,
                             WriteError)


def _issues(items) -> list[dict]:
    return [i.model_dump() for i in items]


def error_response(error: WriteError) -> JSONResponse:
    if isinstance(error, NotFound):
        status, body = 404, {"detail": error.message}
    elif isinstance(error, ValidationFailed):
        status, body = 422, {"detail": error.message, "issues": _issues(error.issues)}
    elif isinstance(error, Duplicate):
        status, body = 409, {"detail": error.message, "code": error.code, "existing_id": error.existing_id,
                             "issues": _issues(error.issues)}
    elif isinstance(error, Conflict):
        status, body = 409, {"detail": error.message, "code": error.code}
    elif isinstance(error, Gone):
        status, body = 410, {"detail": error.message, "code": error.code}
    elif isinstance(error, ServiceUnavailable):
        status, body = 503, {"detail": error.message, "code": error.code}
    else:
        status, body = 400, {"detail": error.message}
    # Datos adicionales seguros del dominio (p. ej. el borrador actualizado o la transcripción)
    return JSONResponse(status_code=status, content={**error.extra, **body})


def install(app: FastAPI) -> None:
    @app.exception_handler(WriteError)
    async def _write_error(request: Request, error: WriteError):
        return error_response(error)

    @app.exception_handler(RequestValidationError)
    async def _request_validation(request: Request, error: RequestValidationError):
        errors = error.errors()
        return JSONResponse(status_code=422, content={"detail": jsonable_encoder(errors),
                                                      "issues": _issues(issues_from_pydantic(errors))})
