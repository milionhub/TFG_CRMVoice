# CRM Voice

Sistema inteligente para el registro automatizado de actividades comerciales mediante voz con integración en CRM.

Proyecto de Trabajo de Fin de Grado (TFG).

# Objetivo del proyecto

Permitir que un comercial registre visitas y tareas hablando, de manera que el sistema sea capaz de:

Transcribir el audio a texto.

Analizar el texto mediante técnicas de Inteligencia Artificial.

Extraer datos relevantes (cliente, fecha, acción, notas).

Almacenar la información en un CRM interno.

Crear eventos automáticamente en Google Calendar cuando se detecten fechas.

# Tecnologías utilizadas

Frontend: Flutter (Web)

Backend: FastAPI (Python)

Control de versiones: GitHub

Entorno operativo: Windows 10

Servidor backend: Uvicorn

Documentación API: Swagger (OpenAPI /docs)

Gestión de dependencias: pip + venv

# Estructura del proyecto

TFG_CRMVoice/
├─ backend/ → API FastAPI
│ ├─ main.py
│ └─ venv/
├─ frontend/ → Aplicación Flutter
│ ├─ lib/
│ │ └─ main.dart
│ └─ web/
├─ docs/ → Documentación del TFG
├─ README.md
└─ .gitignore

# Instalación y ejecución
1. Clonar el repositorio

git clone https://github.com/milionhub/TFG_CRMVoice.git

cd TFG_CRMVoice

# Backend (FastAPI)
2. Crear entorno virtual

cd backend
python -m venv venv
venv\Scripts\activate

3. Instalar dependencias

pip install -r requirements.txt

4. Ejecutar servidor

uvicorn main:app --reload --port 8000

5. Probar API en navegador

Root: http://127.0.0.1:8000/

Ping: http://127.0.0.1:8000/ping

Documentación Swagger: http://127.0.0.1:8000/docs

# Frontend (Flutter Web)

cd frontend
flutter run -d chrome

# Estado del proyecto

✅ Infraestructura creada

✅ Frontend base operativo

✅ Backend funcional

✅ Primer sprint completado

# Autor

Juan Marín Escolano
Trabajo de Fin de Grado — CRM Voice