# Deuda técnica conocida

Backlog de problemas **abiertos** detectados durante la Fase D (tests + CI). Los ya
resueltos no aparecen: B1, B11 y B14 (Fase D), B3, B6, B7, B10, B15 y B16 (Fase E), B12, B13,
F-I2, F-I5 y F-I6 (Fase F), B18, B19 y B20 (Fase G.1), B17, B5 y FE-D7-05 (Fase G.3) y B2
(Fase H.2).

Donde existe, el test que describe el comportamiento deseado está marcado como `xfail`
(backend, `strict=True`) o `skip` (frontend); al corregir el bug, ese test debe pasar a
ser un test normal.

Severidad: **IMPORTANT** (debe corregirse en su fase) · **MINOR** (mejora o riesgo bajo).

## E — Backend / refactor

Sin deuda abierta. Decisión de diseño (B7): `PUT /activities/{id}` es una sustitución
completa con el cuerpo V2 (`ActivityIn`); el estado se cambia con `PATCH`. Desde H.5.2 la
API ya no acepta el formato anterior de la app (Voice V1).

## F — CRM / resolución de entidades

Completada. La resolución contextual (`entity_resolver.resolve_client_and_contact`, que
usan el Action Engine y el chat): un cliente dicho pero no resuelto no se sustituye por el del
contacto (`conflict`), solo se hereda el cliente de un contacto inequívoco cuando no se dijo
ninguno (`inherited`) y la ambigüedad no se resuelve en silencio. (`/process-audio`, que la
expuso primero, se retiró en H.5.2.) Los MINOR pendientes están en H y J.

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

G.6 (aceptación final con OpenAI real sobre una copia de la base) cerró tres fallos
reproducibles: tras identificar un cliente con `find_entities` el modelo negaba que tuviera
contactos, actividades o facturación (el resultado ahora dice que solo identifica); una pregunta
de periodo sin contexto activo ("¿qué tengo mañana?") se respondía sin consultar o con una
aclaración innecesaria (ahora la primera llamada exige una herramienta); y "las actividades del
comercial con id 2" mostraba las del propio usuario atribuyéndoselas a otro (nunca hubo acceso a
datos ajenos; el prompt lo prohíbe ahora de forma explícita).

| ID | Resumen | Severidad |
|---|---|---|
| B4 | `build_context` (solo `GET /client-context`) siempre devuelve un dict: un cliente inexistente responde 200 con `client_name=None` en vez de 404 | MINOR |
| — | Chat: el presupuesto de unos 30 s por petición no es un corte exacto de reloj. Se comprueba antes de cada llamada a OpenAI y el timeout de cada una (conexión + lectura) no supera lo que queda, pero el de lectura de httpx limita la espera entre bytes, no la respuesta completa; la resolución DNS y las esperas por bloqueo de SQLite tampoco cuentan | MINOR |
| — | Chat: sin límite de peticiones ni de coste por usuario; los mensajes de una conversación no caducan (solo el contexto enviado al modelo está acotado); dos peticiones simultáneas a la misma conversación guardan el estado de la última | MINOR |
| — | Chat: la compatibilidad de los esquemas estrictos de las herramientas con la API real de OpenAI solo se valida con la prueba manual (los tests usan un modelo simulado). La búsqueda semántica siempre devuelve los más parecidos aunque la similitud sea baja | MINOR |
| — | Chat: el modo `query_only` cubre las conexiones de `crm_tools`; las lecturas del resolvedor de entidades y de la búsqueda semántica usan conexiones normales (solo hacen SELECT: no hay escritura alcanzable). Los esquemas estrictos con llamadas en paralelo y la detección de llamadas repetidas (textual) quedan acotados por la validación del backend y el tope de 8 herramientas | MINOR |
| — | Chat: el alcance del turno (`chat_scope`) se detecta con pocas señales explícitas (olvidar, "en general", pronombres, "¿y …?", el nombre de la entidad activa); una frase fuera de ellas se trata como ambigua (se pregunta) y "olvida" en otro sentido ("¿se me olvida algo?") también borra el contexto. La guarda solo cubre `list_activities` / `search_activities` acotadas con el estado previo; si el modelo responde sin herramientas o elige global sin preguntar, depende del prompt | MINOR |
| — | Chat: las actividades ya tienen estado (H.2) y existen las ventas y la vista `revenue_lines`, pero el chat todavía no los usa: "pendiente" se responde como "próximas actividades" y la facturación es solo la de las facturas históricas (globales, sin comercial). Integrarlo es parte de H.5. "hoy", "ayer", etc. usan la hora local del servidor | MINOR |
| — | Chat (frontend, tras G.5): el `conversation_id` y el contexto solo viven en memoria (no hay historial ni se recupera la conversación al recargar); el chat gestiona su propio 401 con "Iniciar sesión", pero el resto de la app sigue sin manejo global (FE-02); el tema claro es local al chat (la app sigue con `ThemeData.dark()`); `flutter_markdown` 0.6.x figura como descontinuado en pub.dev (sustituto: `flutter_markdown_plus`) | MINOR |
| — | Chat: el timeout de 45 s del frontend (o un corte de red) no cancela la petición; si el backend acaba y guarda el turno, "Reintentar" con el mismo `conversation_id` lo repite y el historial queda [P, R1, P, R2] (R1 y su metadata nunca se mostraron; la siguiente respuesta trae el contexto bueno). Solo lectura, sin efectos laterales y requiere > 45 s. Arreglarlo exige idempotencia o cancelación en el backend (fuera de G.5) | MINOR |
| — | Chat (Markdown): las imágenes nunca se cargan (se muestra su texto alternativo), pero `flutter_markdown` 0.6.x hace `Uri.parse` del src antes de llamar al `imageBuilder`: una URL de imagen mal formada (p. ej. `http://[::1`) hace fallar el render de ESE mensaje (sin petición de red). Evitarlo exige un builder propio para `img` con `package:markdown` como dependencia directa; revisarlo al migrar a `flutter_markdown_plus` | MINOR |
| — | Chat (G.6): con un periodo relativo y sin contexto activo la primera llamada exige una herramienta, también en una charla ("¿qué tal estás hoy?" consulta la agenda de hoy y la menciona). La detección de periodos es una lista fija (hoy, ayer, mañana, semanas y meses relativos) | MINOR |
| — | Chat (G.6, variación del modelo): a veces responde una continuación con datos de la respuesta anterior sin volver a consultar ("¿y con quién debería hablar allí?" tras preparar la reunión: datos correctos, pero sin herramienta en ese turno), usa alguna valoración prohibida por el prompt ("alto potencial") o termina con una frase de relleno | MINOR |

## H — Voz / actividades V2

H.2 (backend del Action Engine) cerró:
- **B2**: los duplicados de actividad son deterministas (mismo comercial, cliente, contacto
  —NULL incluido—, tipo y minuto, frente a actividades no canceladas) y bloquean con 409 o con un
  issue bloqueante en el borrador; los embeddings ya no intervienen.
- **Estado de actividad**: `pending` / `completed` / `cancelled` (migración m001, con las
  futuras pasadas a pendientes); completada + futura no es válido; pendiente vencida, sí.
- **Coherencia cliente↔contacto en escrituras**: la validan los servicios de escritura
  (actividades y ventas) y, como defensa en profundidad, triggers de SQLite (m005).
- Fechas de actividad siempre `YYYY-MM-DDTHH:MM:SS` (la migración quitó los `.000`).
- `PUT /activities/{id}` exige tipo de actividad, como el alta.

Contrato de H.2 que conviene conocer:
- **Escrituras**: una sola implementación (`services/writes`) para formularios y borradores.
- **Action Engine** (`/actions/*`): el modelo solo extrae menciones (nunca ids), el resolvedor
  determinista pone los ids y nada se escribe hasta confirmar un borrador guardado en el
  servidor, del comercial, con revisión y caducidad (30 min). La confirmación solo acepta la
  revisión vista, revalida contra la BD actual y escribe en la misma transacción que marca el
  borrador como ejecutado (idempotente: confirmar dos veces devuelve el mismo resultado).
- **Ventas** (`sales`, una fila por línea, céntimos enteros) conviven con las facturas
  históricas, que no se tocan; `revenue_lines` las combina indicando el origen.
- **Migraciones** (`migrations.py`, `PRAGMA user_version`): antes de migrar una base que ya
  tenía datos se copia a `<db>.bak-v<versión>` una sola vez (ignorada por git).

| ID | Resumen | Severidad |
|---|---|---|
| — | Whisper se carga en la primera transcripción: un fallo de carga aparece como 500 en esa petición, no al arrancar | MINOR |
| — | Retirado en H.5.2: Voice V1 (`/process-audio`, `/process-text`, `text_analysis`, `date_resolver`, el análisis de `voice_pipeline`, `schemas/voice.py`) y el adaptador del formato anterior de `POST/PUT /activities`. `voice_pipeline` queda solo con el audio de Voice V2 (límites, formatos y transcripción). Sus incidencias (B9, FE-D7-02, FE-D7-03, `detect_action`, horas en texto libre, confianza de `/process-audio`) desaparecen con él | — |
| — | Hora: todo (estado de actividades, fechas futuras de ventas, calendario del intérprete, caducidad de borradores) usa la hora LOCAL del servidor sin zona horaria; se asume que el servidor corre en la zona del usuario (Europe/Madrid) | MINOR |
| — | Action Engine: una petición no soportada (consultas, borrar, completar, varias acciones...) responde 422 sin crear borrador. Los duplicados de actividad son solo exactos (al minuto): una misma llamada a las 10:00 y a las 10:05 no se detecta | MINOR |
| — | Action Engine: la calidad del intérprete con audio real (nombres mal transcritos, importes dichos) solo se ha probado con interpretaciones simuladas; la aceptación con Whisper y OpenAI reales sobre una copia de la BD queda para H.6 | MINOR |

## I — Frontend / UI / UX

| ID | Resumen | Severidad |
|---|---|---|
| FE-02 | No hay manejo global de 401: con un token rechazado la sesión sigue activa (1 `skip`) | IMPORTANT |
| FE-D7-01 | Resuelto en H.3: History y Calendar muestran error con Reintentar | — |
| B8 | Resuelto en H.5.2: `ApiService.getActivity` eliminado (junto con `createActivity`/`updateActivity` del formato anterior) | — |
| FE-D7-04 | Resuelto en H.5.2: `Activity` y `ActivityProvider` (sin uso) eliminados | — |
| — | `flutter analyze` mantiene avisos informativos en código anterior (`withOpacity` deprecado, etc.); `analyzeText` se eliminó en H.4 | MINOR |
| — | Navegación móvil (H.5.2): el menú lateral sustituye la pila como la barra lateral de escritorio; la ficha de cliente y los formularios siguen apilándose (con Atrás) | — |

## J — Calidad final (tests y CI)

| Resumen | Severidad |
|---|---|
| Resolución de entidades: fuzzy permisivo con nombres cortos ("Alba" → Alma, "Villa" → Villademo); un modelo sin palabra de categoría ni alias ("el Nova 14") no se detecta; modelos alfanuméricos ("X27"/"X28") sin comprobación de número; la forma jurídica solo se ignora en el catálogo ("SL" frente a "S.L." queda fuzzy); un alias que es palabra común ("aurora") se detecta como cliente | MINOR |
| Tests frontend: la guarda de `FakeBackend` solo cubre las peticiones hechas dentro de `backend.run`; sin tests de `rememberMe=false` en registro y Google, ni del timeout de `fetchMe`; la rama web de Google (`kIsWeb`) no se puede probar | MINOR |
| Los widget tests dependen de textos e iconos concretos: habrá que actualizarlos con el rediseño de la Fase I | MINOR |
| Tests backend: `test_infra.py` importa `conftest` directamente; dependencias transitivas sin fijar (aviso de deprecación de anyio) | MINOR |
| Emails: la comparación sin mayúsculas usa `lower()` de SQLite, que solo pliega ASCII (una cuenta antigua con mayúsculas no ASCII no se reconocería); la unicidad sigue siendo la del texto guardado | MINOR |
| Tres implementaciones de similitud coseno (`openai_service`, `semantic_search_service`, `/semantic-search`): unificarlas. `/semantic-search` se conserva (H.5.2) como API independiente, sin consumidor en la app ni en el chat, que usa `semantic_search_service`; devuelve `cliente_raw`, vacío en las actividades creadas por formulario o Voice V2 | MINOR |
