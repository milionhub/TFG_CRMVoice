"""
date_resolver (D.4): fechas relativas y horas, deterministas gracias a
`today` (fecha base).
"""
from datetime import datetime

import pytest

from services.date_resolver import resolve_relative_date, resolve_time

# Jueves 1 de octubre de 2026 (weekday() == 3)
THURSDAY = datetime(2026, 10, 1, 12, 0)


def test_base_de_los_tests_es_jueves():
    assert THURSDAY.weekday() == 3


# ---------------------------------------------------------------------
# Fechas relativas
# ---------------------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("hoy", "2026-10-01"),
    ("Hoy he visitado al cliente", "2026-10-01"),
    ("esta mañana", "2026-10-01"),
    ("mañana", "2026-10-02"),
    ("Mañana llamo a Nora", "2026-10-02"),
    ("pasado mañana", "2026-10-03"),
    ("mañana por la mañana", "2026-10-02"),
    ("la semana que viene", "2026-10-08"),
])
def test_fechas_relativas(text, expected):
    assert resolve_relative_date(text, today=THURSDAY) == expected


@pytest.mark.parametrize("text", ["a las 9 de la mañana", "por la mañana"])
def test_de_la_manana_es_franja_horaria_no_el_dia_siguiente(text):
    assert resolve_relative_date(text, today=THURSDAY) is None


@pytest.mark.parametrize("text,expected", [
    ("el lunes", "2026-10-05"),
    ("el martes", "2026-10-06"),
    ("el miércoles", "2026-10-07"),
    ("el miercoles", "2026-10-07"),
    ("el viernes", "2026-10-02"),
    ("el sábado", "2026-10-03"),
    ("el sabado", "2026-10-03"),
    ("el domingo", "2026-10-04"),
])
def test_dia_de_la_semana_es_el_proximo(text, expected):
    assert resolve_relative_date(text, today=THURSDAY) == expected


def test_mismo_dia_de_la_semana_es_dentro_de_siete_dias():
    assert resolve_relative_date("el jueves", today=THURSDAY) == "2026-10-08"


@pytest.mark.parametrize("text,expected", [
    ("el 15/10/2026", "2026-10-15"),
    ("el 5/1/2027", "2027-01-05"),
    ("el 15/10/26", "2026-10-15"),
])
def test_fecha_explicita_dia_mes_anio(text, expected):
    assert resolve_relative_date(text, today=THURSDAY) == expected


def test_fecha_explicita_imposible():
    assert resolve_relative_date("el 31/02/2026", today=THURSDAY) is None


@pytest.mark.parametrize("text", ["", None, "sin ninguna referencia temporal"])
def test_sin_fecha(text):
    assert resolve_relative_date(text, today=THURSDAY) is None


def test_sin_today_usa_la_fecha_actual():
    assert resolve_relative_date("hoy") == datetime.today().strftime("%Y-%m-%d")


# ---------------------------------------------------------------------
# Horas
# ---------------------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("a las 10", "10:00:00"),
    ("a las 6", "06:00:00"),
    ("a la 1", "01:00:00"),
    ("para las 3", "03:00:00"),
    ("18:30", "18:30:00"),
    ("a las 16:45", "16:45:00"),
    ("a las 9 de la mañana", "09:00:00"),
    ("a las 6 de la tarde", "18:00:00"),
    ("a las 10 de la noche", "22:00:00"),
])
def test_horas_soportadas(text, expected):
    assert resolve_time(text) == expected


@pytest.mark.parametrize("text", ["", None, "sin hora"])
def test_sin_hora(text):
    assert resolve_time(text) is None


# ---------------------------------------------------------------------
# B11: medias, cuartos y horas en palabras
# ---------------------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    # y media
    ("a las 4 y media", "04:30:00"),
    ("pasado mañana a las 4 y media", "04:30:00"),
    ("a las cuatro y media", "04:30:00"),
    ("pasado mañana a las cuatro y media", "04:30:00"),
    ("a la una y media", "01:30:00"),
    # y cuarto
    ("a las 4 y cuarto", "04:15:00"),
    ("a las cuatro y cuarto", "04:15:00"),
    # menos cuarto: se resta a la hora nombrada
    ("a las 5 menos cuarto", "04:45:00"),
    ("a las cinco menos cuarto", "04:45:00"),
    ("a la una menos cuarto", "00:45:00"),
    # horas en palabras sin fracción
    ("a las diez", "10:00:00"),
    ("a la una", "01:00:00"),
    ("a las doce", "12:00:00"),
])
def test_b11_medias_cuartos_y_horas_en_palabras(text, expected):
    assert resolve_time(text) == expected


@pytest.mark.parametrize("text,expected", [
    ("a las 4 y media de la tarde", "16:30:00"),
    ("a las cuatro y media de la tarde", "16:30:00"),
    ("a las 9 y cuarto de la noche", "21:15:00"),
    ("a las cinco menos cuarto de la tarde", "16:45:00"),
    ("a las 9 y media de la mañana", "09:30:00"),
    ("mañana a las 10 y media", "10:30:00"),  # "mañana" (día) no cambia la hora
    ("a las doce y media de la mañana", "00:30:00"),  # misma semántica que "12 de la mañana"
    ("a las doce menos cuarto de la mañana", "11:45:00"),
    ("a las 12 y media de la tarde", "12:30:00"),
    ("a la una menos cuarto de la tarde", "12:45:00"),
])
def test_b11_franja_horaria_con_fracciones(text, expected):
    assert resolve_time(text) == expected


def test_b11_la_fraccion_debe_ir_justo_despues_de_la_hora():
    # "media" suelta más adelante no es parte de la hora
    assert resolve_time("a las 4 para hablar media hora") == "04:00:00"


# ---------------------------------------------------------------------
# B14: horas y minutos imposibles
# ---------------------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("a las 0", "00:00:00"),
    ("a las 23", "23:00:00"),
    ("00:00", "00:00:00"),
    ("23:59", "23:59:00"),
    ("a las 23 y media", "23:30:00"),
])
def test_b14_limites_validos(text, expected):
    assert resolve_time(text) == expected


@pytest.mark.parametrize("text", ["a las 25", "a las 24", "a las 99 y media", "25:00", "24:00", "18:60", "18:75"])
def test_b14_hora_imposible_no_se_acepta(text):
    assert resolve_time(text) is None
