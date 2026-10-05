"""
Modelo único de "problema" (issue) para las escrituras y los borradores (H.2).

Lo usan los servicios de escritura (errores 409/422 con issues) y el Action
Engine (issues de un borrador). blocking=True impide guardar / confirmar.
"""
from typing import Literal

from pydantic import BaseModel, ConfigDict

IssueCode = Literal["missing", "ambiguous", "not_found", "conflict", "invalid", "duplicate",
                    "similar", "fuzzy_match", "unsupported"]


class Candidate(BaseModel):
    """Opción emitida por el servidor para resolver una ambigüedad (id real + etiqueta)."""
    model_config = ConfigDict(extra="forbid")

    id: int
    label: str


class Issue(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: IssueCode
    field: str                  # "client", "contact", "datetime", "products[0]", "lines[0].product"...
    message: str                # en español, para el usuario
    blocking: bool
    candidates: list[Candidate] = []
    existing_id: int | None = None   # en "duplicate": el registro que ya existe


def issue(code: IssueCode, field: str, message: str, *, blocking: bool = True,
          candidates: list[Candidate] | None = None, existing_id: int | None = None) -> Issue:
    return Issue(code=code, field=field, message=message, blocking=blocking,
                 candidates=candidates or [], existing_id=existing_id)


def has_blocking(issues: list[Issue]) -> bool:
    return any(i.blocking for i in issues)


# ---------------------------------------------------------------------
# Errores de Pydantic -> issues en español (formularios, adaptador y API)
# ---------------------------------------------------------------------

def _spanish_message(err: dict) -> tuple[str, str]:
    """(code, mensaje) legible para un error de validación de Pydantic."""
    kind = err.get("type", "")
    ctx = err.get("ctx") or {}
    if kind == "missing" or (kind != "value_error" and "input" in err and err["input"] is None):
        return "missing", "Campo obligatorio."
    if kind == "value_error":
        return "invalid", str(err.get("msg", "")).removeprefix("Value error, ")
    messages = {
        "int_type": "Debe ser un número entero.",
        "int_parsing": "Debe ser un número entero.",
        "string_type": "Debe ser un texto.",
        "bool_type": "Debe ser verdadero o falso.",
        "list_type": "Debe ser una lista.",
        "dict_type": "Debe ser un objeto.",
        "model_type": "Debe ser un objeto.",
        "literal_error": "Valor no permitido.",
        "extra_forbidden": "Campo no permitido.",
        "string_too_short": f"Demasiado corto (mínimo {ctx.get('min_length')} caracteres).",
        "string_too_long": f"Demasiado largo (máximo {ctx.get('max_length')} caracteres).",
        "too_short": f"Debe tener al menos {ctx.get('min_length')} elementos.",
        "too_long": f"Puede tener como mucho {ctx.get('max_length')} elementos.",
        "greater_than_equal": f"Debe ser mayor o igual que {ctx.get('ge')}.",
        "less_than_equal": f"Debe ser menor o igual que {ctx.get('le')}.",
        "greater_than": f"Debe ser mayor que {ctx.get('gt')}.",
        "json_invalid": "JSON no válido.",
    }
    return "invalid", messages.get(kind, "Valor no válido.")


def issues_from_pydantic(errors, *, prefix: str = "", skip=("body", "query", "path")) -> list[Issue]:
    """Lista de errores de Pydantic -> issues con un campo legible ("lines[0].amount")."""
    result = []
    for err in errors:
        parts: list[str] = []
        for part in err.get("loc", ()):
            if isinstance(part, int):
                if parts:
                    parts[-1] = f"{parts[-1]}[{part}]"
                else:
                    parts.append(f"[{part}]")
            elif part not in skip and part not in ("str", "int", "constrained-str", "function-after"):
                parts.append(str(part))
        field = ".".join(([prefix] if prefix else []) + parts) or prefix or "body"
        code, message = _spanish_message(err)
        result.append(issue(code, field, message))
    return result
