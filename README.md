# CRMVoice

Registro de actividades comerciales por voz: el comercial graba un audio, el backend
lo transcribe con Whisper, extrae cliente, contacto, acción, fecha y productos, y el
usuario revisa y guarda la actividad en el CRM. Incluye histórico, calendario y un
chat con IA sobre los datos del CRM.

Proyecto desarrollado como Trabajo de Fin de Grado (TFG).

- **Backend:** Python + FastAPI + SQLite (`backend/`)
- **Frontend:** Flutter, orientado a web (`frontend/`)

---

## Componentes: qué es local y qué es externo

| Componente | Dónde se ejecuta | Para qué | ¿Necesario? |
|---|---|---|---|
| SQLite (`backend/crm.db`) | Local, fichero | Datos del CRM. Se crea solo al arrancar el backend | Sí |
| Whisper (modelo `base`) | Local, CPU | Transcripción del audio | Sí (para grabar actividades por voz) |
| FFmpeg | Local, programa del sistema | Whisper lo usa para decodificar el audio | Sí (para grabar actividades por voz) |
| OpenAI API | Externo, de pago | Embeddings (duplicados, búsqueda semántica), router del chat y resúmenes | La clave es obligatoria para arrancar; las funciones de IA del chat dependen de ella |
| Google OAuth | Externo | Login con Google | Opcional (también hay registro con email y contraseña) |

---

## Requisitos previos

| Herramienta | Versión | Comprobación |
|---|---|---|
| Python | 3.11 (probado con 3.11.2; `numpy` 2.3 requiere 3.11 o superior) | `python --version` (macOS/Linux: `python3 --version`) |
| FFmpeg | Cualquier versión reciente (probado con 8.0.1) en el `PATH` | `ffmpeg -version` |
| Flutter | 3.38 o superior (Dart ≥ 3.10.3; probado con Flutter 3.41.0) | `flutter --version` |
| Google Chrome | — | — |
| Clave de API de OpenAI | — | — |

Instalar FFmpeg:
- **Windows:** `winget install Gyan.FFmpeg` (o descargar un build de https://www.gyan.dev/ffmpeg/builds/ y añadir su carpeta `bin` al `PATH`).
- **macOS:** `brew install ffmpeg`
- **Debian/Ubuntu:** `sudo apt install ffmpeg`

---

## Backend

Todos los comandos de esta sección se ejecutan **dentro de `backend/`**. Desde la raíz del repositorio:

```bash
cd backend
```

Crear el entorno virtual e instalar dependencias:

```bash
# Windows (PowerShell o cmd)
python -m venv venv
venv\Scripts\activate

# macOS / Linux
python3 -m venv venv
source venv/bin/activate

# Con el venv activo, en cualquier sistema:
pip install -r requirements.txt
```

La instalación descarga PyTorch (lo necesita Whisper) y ocupa en torno a 1 GB.
En Windows y macOS, pip instala la versión solo-CPU. **En Linux**, pip instala por
defecto la versión con CUDA (varios GB); si no tienes GPU, instala antes la versión
solo-CPU:

```bash
pip install torch==2.10.0 --index-url https://download.pytorch.org/whl/cpu
pip install -r requirements.txt
```

### Configuración

```bash
# Windows
copy .env.example .env
# macOS / Linux
cp .env.example .env
```

Edita `backend/.env` y rellena los valores vacíos:

| Variable | Obligatoria | Descripción |
|---|---|---|
| `OPENAI_API_KEY` | Sí | Clave de la API de OpenAI |
| `SECRET_KEY` | Sí | Clave aleatoria para firmar los JWT (mínimo 32 caracteres). Ver abajo cómo generarla |
| `ALGORITHM` | Sí | Algoritmo del JWT: `HS256` (también se admiten `HS384` y `HS512`) |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | Sí | Duración de la sesión en minutos, por ejemplo `60` |
| `GOOGLE_CLIENT_ID` | No | OAuth Client ID de Google (ver [Login con Google](#login-con-google-opcional)). Sin él, `/auth/google` responde 503 |

Generar la `SECRET_KEY` y pegarla en `.env`:

```bash
# Windows
python -c "import secrets; print(secrets.token_urlsafe(64))"
# macOS / Linux
python3 -c "import secrets; print(secrets.token_urlsafe(64))"
```

Si falta alguna variable obligatoria o se deja un valor de ejemplo, el backend no arranca
y el error indica qué corregir.

### Datos

`crm.db` no está en el repositorio. Al arrancar, el backend crea las tablas y los 5 tipos
de actividad que reconoce el análisis de voz (datos de referencia), pero no hay clientes ni
productos: sin ellos no se puede reconocer ni guardar ninguna actividad.

Para probar la app, carga el catálogo de demostración. Todos sus datos son **ficticios**
(empresas "Demo", personas y productos inventados):

```bash
python seed_demo_data.py
```

Crea 5 clientes, 7 contactos, 6 productos (con alias para el reconocimiento por voz) y
8 facturas. No crea usuarios (regístrate desde la app) ni actividades. Si la base de datos
ya tiene datos de catálogo, no modifica nada.

### Arrancar

```bash
uvicorn main:app --reload --port 8000
```

El primer arranque descarga el modelo `base` de Whisper (~140 MB, en `~/.cache/whisper`),
así que tarda más y necesita conexión a Internet.

Comprobación rápida:
- http://127.0.0.1:8000/ping → `{"status":"ok"}`
- http://127.0.0.1:8000/docs → documentación de la API

---

## Frontend

Todos los comandos de esta sección se ejecutan **dentro de `frontend/`**. Desde la raíz del
repositorio (en otra terminal, con el backend arrancado):

```bash
cd frontend
flutter pub get
```

### Configuración

El frontend se configura al arrancar con `--dart-define`, sin editar código:

| Variable | Por defecto | Descripción |
|---|---|---|
| `API_BASE_URL` | `http://127.0.0.1:8000` | URL del backend |
| `GOOGLE_CLIENT_ID` | vacío | OAuth Client ID de Google. Si está vacío, no se muestra el botón de Google |

La forma más cómoda es un fichero local (está en `.gitignore`):

```bash
# Windows
copy dart_defines.example.json dart_defines.json
# macOS / Linux
cp dart_defines.example.json dart_defines.json
```

### Arrancar

```bash
flutter run -d chrome --web-port 5000 --dart-define-from-file=dart_defines.json
```

Equivalente sin fichero:

```bash
flutter run -d chrome --web-port 5000 --dart-define=API_BASE_URL=http://127.0.0.1:8000 --dart-define=GOOGLE_CLIENT_ID=TU_CLIENT_ID.apps.googleusercontent.com
```

- El puerto fijo (`--web-port 5000`) es necesario para el login con Google: Google solo
  acepta los orígenes que tengas autorizados.
- Los valores de `--dart-define` se aplican al compilar: si los cambias, detén
  `flutter run` y vuelve a lanzarlo (el hot reload no los recoge).

---

## Login con Google (opcional)

1. En [Google Cloud Console](https://console.cloud.google.com/) → *APIs & Services* →
   *Credentials* → *Create credentials* → *OAuth client ID* → tipo **Web application**.
2. En *Authorized JavaScript origins* añade el origen exacto desde el que abres la app:
   `http://localhost:5000` (y `http://127.0.0.1:5000` si usas esa dirección; para Google
   son orígenes distintos). No hace falta ninguna *redirect URI*.
3. Usa el mismo Client ID en los dos lados:
   - backend: `GOOGLE_CLIENT_ID` en `backend/.env`
   - frontend: `GOOGLE_CLIENT_ID` en `frontend/dart_defines.json`

El frontend envía a `/auth/google` el **ID token** de Google y el backend verifica su
firma, emisor, caducidad y que `aud` sea tu Client ID.

---

## Primer uso

1. Backend y frontend arrancados, con el catálogo de demostración cargado.
2. En la app, pestaña **Sign Up**: crea tu usuario.
3. En Inicio, mantén pulsado el micrófono y di, por ejemplo:
   *"Concertar reunión mañana a las 10 con Nora Quintana de Nebula para presentarle el monitor Vela 24"*.
4. Revisa la actividad detectada y guárdala. Aparecerá en Histórico y Calendario.

---

## Tests

Desde la raíz del repositorio:

```bash
cd frontend
flutter test test/auth_provider_logout_test.dart
```

`test/widget_test.dart` es la plantilla original de Flutter y todavía no está adaptada.
El backend aún no tiene tests automatizados.

---

## Problemas frecuentes

| Síntoma | Causa y solución |
|---|---|
| PowerShell no deja activar el venv ("la ejecución de scripts está deshabilitada") | Permítelo solo en esa terminal: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` y vuelve a ejecutar `venv\Scripts\activate` |
| El backend no arranca: `Configuración del backend no válida` | Falta `backend/.env`, alguna variable o sigue un valor de ejemplo. El mensaje indica cuál; la `SECRET_KEY` se genera como se explica en [Configuración](#configuración) |
| Aviso `FFmpeg no está en el PATH` al arrancar, o "Error enviando audio" al grabar | Instala FFmpeg y comprueba `ffmpeg -version` en la misma terminal donde arrancas el backend |
| Al guardar una actividad: "Cliente obligatorio"; nunca se reconoce ningún cliente | La base de datos no tiene catálogo: ejecuta `python seed_demo_data.py` |
| No aparece el botón de Google | Falta `GOOGLE_CLIENT_ID` en el frontend (`dart_defines.json` o `--dart-define`) |
| El botón de Google da error / "origin is not allowed" | El origen (host y puerto exactos) no está autorizado en Google Cloud. Usa `--web-port 5000` y autoriza `http://localhost:5000` |
| "Error con Google Login" | Mira el log del backend: 503 si falta `GOOGLE_CLIENT_ID` en `backend/.env`; 401 si el Client ID del backend no coincide con el del frontend |
| La app no conecta con el backend | Revisa `API_BASE_URL`. Desde otro dispositivo usa la IP del PC y arranca el backend con `--host 0.0.0.0` |

---

## Estructura

```
backend/
  main.py              API (FastAPI)
  db.py                SQLite: conexión, tablas y tipos de actividad
  env_check.py         validación de la configuración al arrancar
  whisper_service.py   transcripción local
  entity_resolver.py   resolución de cliente, contacto y productos
  date_resolver.py     fechas y horas relativas
  openai_service.py    embeddings y resúmenes
  seed_demo_data.py    catálogo de demostración (datos ficticios)
  .env.example         plantilla de configuración
frontend/
  lib/                 app Flutter
  web/index.html
  dart_defines.example.json
```

Autor: Juan Marín Escolano
