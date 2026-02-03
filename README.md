🧠 CRM Voice

Sistema inteligente para el registro automatizado de actividades comerciales mediante voz, con procesamiento de audio real, Inteligencia Artificial y almacenamiento estructurado en CRM.

Proyecto desarrollado como Trabajo de Fin de Grado (TFG).

🎯 Objetivo del proyecto

El objetivo de CRM Voice es permitir que un comercial registre visitas, llamadas y tareas simplemente hablando, eliminando la necesidad de introducir datos manualmente.

El sistema es capaz de:

Grabar audio de voz desde una aplicación web.

Transcribir audio real a texto mediante Speech To Text basado en IA (Whisper).

Analizar automáticamente el texto generado.

Extraer información relevante:

Cliente

Acción comercial

Fecha

Comentarios

Almacenar la información en un CRM interno.

Mantener trazabilidad completa entre audio, transcripción y actividad.

Preparar el sistema para futuras integraciones (calendarios, clientes, empresas).

🧩 Flujo funcional del sistema
Grabación de voz (Flutter)
→ Envío de audio al backend
→ Transcripción automática con IA (Whisper)
→ Análisis semántico del texto
→ Enriquecimiento de la actividad CRM
→ Almacenamiento en base de datos
→ Visualización en histórico

🛠️ Tecnologías utilizadas
Frontend

Flutter (Web)

Grabación de audio desde navegador

Comunicación HTTP con backend

Backend

FastAPI (Python)

Motor ASR: Whisper (Speech To Text)

Base de datos: SQLite

Servidor ASGI: Uvicorn

Análisis semántico basado en reglas

Herramientas adicionales

Git & GitHub (control de versiones)

Swagger / OpenAPI (documentación API)

Entornos virtuales Python (venv)

FFmpeg (procesamiento de audio)

📁 Estructura del proyecto
TFG_CRMVoice/
├─ backend/                 → API FastAPI
│  ├─ main.py               → Endpoints principales
│  ├─ whisper_service.py    → Servicio de transcripción con IA
│  ├─ db.py                 → Gestión de base de datos
│  ├─ requirements.txt
│  └─ venv/
│
├─ frontend/                → Aplicación Flutter Web
│  ├─ lib/
│  │  ├─ main.dart
│  │  ├─ history_page.dart
│  │  └─ services/
│  │     └─ api_service.dart
│  └─ web/
│
├─ docs/                    → Documentación del TFG
├─ README.md
└─ .gitignore

🚀 Instalación y ejecución
1️⃣ Clonar el repositorio
git clone https://github.com/milionhub/TFG_CRMVoice.git
cd TFG_CRMVoice

2️⃣ Backend (FastAPI)
cd backend
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
uvicorn main:app --reload --port 8000

Endpoints disponibles

Root: http://127.0.0.1:8000/

Ping: http://127.0.0.1:8000/ping

Swagger UI: http://127.0.0.1:8000/docs

3️⃣ Frontend (Flutter Web)
cd frontend
flutter run -d chrome


Desde la interfaz se puede:

Grabar audio

Enviar audio al backend

Ver el histórico de actividades CRM

📊 Estado actual del proyecto

✅ Arquitectura completa frontend–backend
✅ Grabación de audio real
✅ Transcripción automática con IA (Whisper)
✅ Análisis semántico del texto
✅ Persistencia completa en base de datos
✅ Histórico de actividades CRM
✅ Flujo extremo a extremo validado

🔮 Trabajo futuro

Gestión avanzada de clientes y empresas.

Asociación automática con datos fiscales (CIF, teléfono, email).

Integración con Google Calendar.

Mejora del análisis semántico con NLP avanzado.

Autenticación y control de usuarios.

👤 Autor

Juan Marín Escolano
Trabajo de Fin de Grado — CRM Voice