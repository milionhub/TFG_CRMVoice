# Deuda técnica conocida

Backlog de problemas **abiertos** detectados durante la Fase D (tests + CI). Los ya
resueltos no aparecen: B1, B11 y B14 (Fase D) y B3, B6, B7, B10, B15 y B16 (Fase E).

Donde existe, el test que describe el comportamiento deseado está marcado como `xfail`
(backend, `strict=True`) o `skip` (frontend); al corregir el bug, ese test debe pasar a
ser un test normal.

Severidad: **IMPORTANT** (debe corregirse en su fase) · **MINOR** (mejora o riesgo bajo).

## E — Backend / refactor

Sin deuda abierta. Decisión de diseño (B7): `PUT /activities/{id}` es una sustitución
completa; si falta `fecha`, `client_id`, `contact_id`, `activity_type_id` o `products`
responde 422 (no hay `PATCH`). El `comentario` es opcional: si no se envía, se conserva.

## F — CRM / resolución de entidades

| ID | Resumen | Severidad |
|---|---|---|
| B12 | Un producto que solo difiere en el número se resuelve mal: "Nova 15" → "Portátil Nova 14" (1 `xfail`) | IMPORTANT |
| B13 | Falsos positivos de las regex de `analyze_text`: el verbo inicial como contacto ("Enviar"), el cliente que absorbe palabras ("Orion Consultoría Hoy"), el cliente truncado ("Clínica") (2 `xfail`) | MINOR |
| — | Sin detección de ambigüedad: un nombre de pila repetido resuelve a uno cualquiera; fuzzy permisivo ("Rivero" → Rivera) | MINOR |

## G — Chat IA V2

| ID | Resumen | Severidad |
|---|---|---|
| B18 | El texto de las excepciones de OpenAI llega al usuario ("Error generando resumen: …"), incluida la clave enmascarada (2 `xfail`) | IMPORTANT |
| B19 | Los fallos de OpenAI en `client_summary` y en la búsqueda semántica devuelven 500 (2 `xfail`) | IMPORTANT |
| B17 | La intención pendiente de `client_summary` nunca se resuelve y repite la pregunta (1 `xfail`) | IMPORTANT |
| B20 | La salida del router no se valida: `confidence` no numérica o JSON que no es objeto → 500 (3 `xfail`) | MINOR |
| B4 | `build_context` siempre devuelve un dict: un cliente inexistente llega a OpenAI con `client_name=None` (rama "no encontrado" muerta) | MINOR |
| B5 | `client_summary` llama a OpenAI y descarta el resultado (coste sin uso) | MINOR |
| FE-D7-05 | El chat del frontend monta la cabecera a mano: sin token enviaría `Bearer null` | MINOR |
| — | La rama `client_analysis` es inalcanzable; un mensaje vacío llega al LLM; la memoria no tiene TTL ni reset, es local al proceso y una intención pendiente no caduca | MINOR |

## H — Voz / actividades V2

| ID | Resumen | Severidad |
|---|---|---|
| B2 | La detección de duplicados nunca se activa (compara `substr(fecha,1,10)` con la fecha completa) y no filtra por comercial; hay que arreglar las dos cosas a la vez | IMPORTANT |
| FE-D7-02 | NewActivity: un error de red o un 500 al guardar no muestra ningún aviso (excepción no controlada) (1 `skip`) | IMPORTANT |
| B9 | `/process-text` solo aplica regex (sin ids, productos ni hora) y diverge de `/process-audio`; el frontend no lo usa | MINOR |
| FE-D7-03 | El botón de guardar no se deshabilita mientras guarda: posible doble envío (1 `skip`) | MINOR |
| — | Horas: "10h" y "9h30" no se reconocen; cantidades en palabras se toman como hora ("a las dos clínicas" → 02:00); solo se entienden "y media", "y cuarto" y "menos cuarto"; "12 de la noche" → 12:00; el día de la semana tiene prioridad sobre una fecha explícita; una hora sin fecha se descarta | MINOR |
| — | Whisper se carga en la primera transcripción: un fallo de carga aparece como 500 en esa petición, no al arrancar | MINOR |
| — | `PUT /activities/{id}` no exige "contacto o tipo de actividad" como el alta: una edición puede dejar ambos en null | MINOR |

## I — Frontend / UI / UX

| ID | Resumen | Severidad |
|---|---|---|
| FE-02 | No hay manejo global de 401: con un token rechazado la sesión sigue activa (1 `skip`) | IMPORTANT |
| FE-D7-01 | History (actividades y filtros) y Calendar no capturan errores: spinner infinito sin aviso y `setState` sin comprobar `mounted` (2 `skip`) | IMPORTANT |
| B8 | `ApiService.getActivity` llama a `GET /activities/{id}`, que no existe (405); no se usa: eliminarlo | MINOR |
| FE-D7-04 | `Activity.fromJson` falla con `comentario` null; `Activity` y `ActivityProvider` no se usan en ninguna pantalla (1 `skip`) | MINOR |
| — | `ApiService.analyzeText` no se usa; `flutter analyze` mantiene 53 avisos informativos (`withOpacity` deprecado, etc.) | MINOR |

## J — Calidad final (tests y CI)

| Resumen | Severidad |
|---|---|
| Tests frontend: la guarda de `FakeBackend` solo cubre las peticiones hechas dentro de `backend.run`; sin tests de `rememberMe=false` en registro y Google, ni del timeout de `fetchMe`; la rama web de Google (`kIsWeb`) no se puede probar | MINOR |
| Los widget tests dependen de textos e iconos concretos: habrá que actualizarlos con el rediseño de la Fase I | MINOR |
| Tests backend: `test_infra.py` importa `conftest` directamente; dependencias transitivas sin fijar (aviso de deprecación de anyio) | MINOR |
| Emails: la comparación sin mayúsculas usa `lower()` de SQLite, que solo pliega ASCII (una cuenta antigua con mayúsculas no ASCII no se reconocería); la unicidad sigue siendo la del texto guardado | MINOR |
| Tres implementaciones de similitud coseno (`openai_service`, `semantic_search_service`, `/semantic-search`): unificarlas junto con la búsqueda del chat (Fase G) | MINOR |
