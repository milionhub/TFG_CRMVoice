# Deuda técnica conocida

Backlog de problemas **abiertos** detectados durante la Fase D (tests + CI). Los ya
resueltos no aparecen: B1, B11 y B14 (Fase D), B3, B6, B7, B10, B15 y B16 (Fase E), B12, B13,
F-I2, F-I5 y F-I6 (Fase F), B18, B19 y B20 (Fase G.1) y B17, B5 y FE-D7-05 (Fase G.3).

Donde existe, el test que describe el comportamiento deseado está marcado como `xfail`
(backend, `strict=True`) o `skip` (frontend); al corregir el bug, ese test debe pasar a
ser un test normal.

Severidad: **IMPORTANT** (debe corregirse en su fase) · **MINOR** (mejora o riesgo bajo).

## E — Backend / refactor

Sin deuda abierta. Decisión de diseño (B7): `PUT /activities/{id}` es una sustitución
completa; si falta `fecha`, `client_id`, `contact_id`, `activity_type_id` o `products`
responde 422 (no hay `PATCH`). El `comentario` es opcional: si no se envía, se conserva.

## F — CRM / resolución de entidades

Completada. `/process-audio` expone de forma aditiva `cliente_status`, `cliente_origen`,
`cliente_candidates`, `contacto_status` y `contacto_candidates`: un cliente dicho pero no
resuelto no se sustituye por el del contacto (`conflict`), solo se hereda el cliente de un
contacto inequívoco cuando no se dijo ninguno (`inherited`) y la ambigüedad no se resuelve
en silencio. La confianza solo pondera lo mencionado. Los MINOR pendientes están en H y J.

## G — Chat IA V2

G.3 sustituyó el chat por ramas (router de intención, detector por palabras, memoria en
diccionarios del proceso e intención pendiente) por un orquestador de solo lectura con
conversaciones persistentes (`chat_conversations` / `chat_messages`), herramientas en lista
blanca y estado activo derivado de los resultados de las herramientas. Eso cierra B17
(la intención pendiente de `client_summary` repetía la pregunta), B5 (resumen de OpenAI
descartado) y la memoria sin TTL ni reset, local al proceso. `POST /prepare-meeting` se
eliminó (el chat usa `prepare_meeting_context`). FE-D7-05 (`Bearer null`) se corrigió.

G.4 (fiabilidad e inteligencia, sin cambios de esquema) cerró dos MINOR de la revisión de G.3:
los ids de un resultado descartado por el tope de evidencia ya no pasan a ser de confianza
(solo cuenta lo que llega al modelo), y un fallo de SQLite al guardar el turno devuelve un
error controlado (sin medio turno guardado) en vez de un 500.

G.5 (Chat V2 en Flutter) cerró los avisos del frontend: el contexto se pinta solo desde
`metadata.active_client` / `active_contact` (ya no se deduce del texto: adiós a "Cliente
activo: s he hablado…"), la conversación sobrevive al cambio escritorio ↔ móvil, el Markdown
usa un tema claro propio del chat (sin texto ilegible sobre el tema oscuro) y se eliminaron
la intención pendiente, las tarjetas antiguas y los botones de acciones sugeridas.

| ID | Resumen | Severidad |
|---|---|---|
| B4 | `build_context` (solo `GET /client-context`) siempre devuelve un dict: un cliente inexistente responde 200 con `client_name=None` en vez de 404 | MINOR |
| — | `activities.datetime_iso` se guarda tal como llega (hay valores con y sin milisegundos, sin validar): las herramientas CRM (G.2) comparan como texto ISO y un formato distinto quedaría fuera de los filtros por fecha. `activities` no tiene estado (pendiente/hecha/cancelada): solo se distingue pasada/próxima | MINOR |
| — | Chat: el presupuesto de unos 30 s por petición no es un corte exacto de reloj. Se comprueba antes de cada llamada a OpenAI y el timeout de cada una (conexión + lectura) no supera lo que queda, pero el de lectura de httpx limita la espera entre bytes, no la respuesta completa; la resolución DNS y las esperas por bloqueo de SQLite tampoco cuentan | MINOR |
| — | Chat: sin límite de peticiones ni de coste por usuario; los mensajes de una conversación no caducan (solo el contexto enviado al modelo está acotado); dos peticiones simultáneas a la misma conversación guardan el estado de la última | MINOR |
| — | Chat: la compatibilidad de los esquemas estrictos de las herramientas con la API real de OpenAI solo se valida con la prueba manual (los tests usan un modelo simulado). La búsqueda semántica siempre devuelve los más parecidos aunque la similitud sea baja | MINOR |
| — | Chat: el modo `query_only` cubre las conexiones de `crm_tools`; las lecturas del resolvedor de entidades y de la búsqueda semántica usan conexiones normales (solo hacen SELECT: no hay escritura alcanzable). Los esquemas estrictos con llamadas en paralelo y la detección de llamadas repetidas (textual) quedan acotados por la validación del backend y el tope de 8 herramientas | MINOR |
| — | Chat: el alcance del turno (`chat_scope`) se detecta con pocas señales explícitas (olvidar, "en general", pronombres, "¿y …?", el nombre de la entidad activa); una frase fuera de ellas se trata como ambigua (se pregunta) y "olvida" en otro sentido ("¿se me olvida algo?") también borra el contexto. La guarda solo cubre `list_activities` / `search_activities` acotadas con el estado previo; si el modelo responde sin herramientas o elige global sin preguntar, depende del prompt | MINOR |
| — | Chat: "pendiente" solo puede responderse como "próximas actividades" porque `activities` no guarda estado; la facturación es global (las facturas no tienen comercial); "hoy", "ayer", etc. usan la hora local del servidor | MINOR |
| — | Chat (frontend, tras G.5): el `conversation_id` y el contexto solo viven en memoria (no hay historial ni se recupera la conversación al recargar); el chat gestiona su propio 401 con "Iniciar sesión", pero el resto de la app sigue sin manejo global (FE-02); el tema claro es local al chat (la app sigue con `ThemeData.dark()`); `flutter_markdown` 0.6.x figura como descontinuado en pub.dev (sustituto: `flutter_markdown_plus`) | MINOR |
| — | Chat: el timeout de 45 s del frontend (o un corte de red) no cancela la petición; si el backend acaba y guarda el turno, "Reintentar" con el mismo `conversation_id` lo repite y el historial queda [P, R1, P, R2] (R1 y su metadata nunca se mostraron; la siguiente respuesta trae el contexto bueno). Solo lectura, sin efectos laterales y requiere > 45 s. Arreglarlo exige idempotencia o cancelación en el backend (fuera de G.5) | MINOR |
| — | Chat (Markdown): las imágenes nunca se cargan (se muestra su texto alternativo), pero `flutter_markdown` 0.6.x hace `Uri.parse` del src antes de llamar al `imageBuilder`: una URL de imagen mal formada (p. ej. `http://[::1`) hace fallar el render de ESE mensaje (sin petición de red). Evitarlo exige un builder propio para `img` con `package:markdown` como dependencia directa; revisarlo al migrar a `flutter_markdown_plus` | MINOR |

## H — Voz / actividades V2

| ID | Resumen | Severidad |
|---|---|---|
| — | `detect_action` no reconoce "seguimiento", "email", "presentar", "llamé"… y el orden de las reglas prioriza "oferta" sobre "visita"/"reunión" | MINOR |
| — | `/process-audio` no distingue un producto mencionado pero no reconocido de uno no mencionado (`resolve_products` solo devuelve los reconocidos): la confianza no lo penaliza | MINOR |
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
| Resolución de entidades: fuzzy permisivo con nombres cortos ("Alba" → Alma, "Villa" → Villademo); un modelo sin palabra de categoría ni alias ("el Nova 14") no se detecta; modelos alfanuméricos ("X27"/"X28") sin comprobación de número; la forma jurídica solo se ignora en el catálogo ("SL" frente a "S.L." queda fuzzy); un alias que es palabra común ("aurora") se detecta como cliente | MINOR |
| Extracción de cliente: con dos empresas en la frase, una que no está en el catálogo se sustituye por la que sí está; un nombre con "de" fuera del catálogo se reduce a su parte final ("Ayuntamiento de X" → "X") | MINOR |
| Tests frontend: la guarda de `FakeBackend` solo cubre las peticiones hechas dentro de `backend.run`; sin tests de `rememberMe=false` en registro y Google, ni del timeout de `fetchMe`; la rama web de Google (`kIsWeb`) no se puede probar | MINOR |
| Los widget tests dependen de textos e iconos concretos: habrá que actualizarlos con el rediseño de la Fase I | MINOR |
| Tests backend: `test_infra.py` importa `conftest` directamente; dependencias transitivas sin fijar (aviso de deprecación de anyio) | MINOR |
| Emails: la comparación sin mayúsculas usa `lower()` de SQLite, que solo pliega ASCII (una cuenta antigua con mayúsculas no ASCII no se reconocería); la unicidad sigue siendo la del texto guardado | MINOR |
| Tres implementaciones de similitud coseno (`openai_service`, `semantic_search_service`, `/semantic-search`): unificarlas junto con la búsqueda del chat (Fase G) | MINOR |
