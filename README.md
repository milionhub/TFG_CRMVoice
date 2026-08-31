# CRMVoice

**CRMVoice** es una aplicación multiplataforma desarrollada como Trabajo Fin de Grado en Ingeniería Informática, orientada a automatizar el registro de actividades comerciales mediante **voz e inteligencia artificial**.

El sistema permite transformar información expresada de forma natural por un usuario en **datos estructurados dentro de un entorno CRM**, reduciendo la necesidad de introducir manualmente la información después de llamadas, reuniones o visitas comerciales.

## 🎥 Demo

▶️ [Ver demostración de CRMVoice en YouTube](https://youtu.be/q53N6HA2MYY)

---

## 💡 Problema

En muchos entornos comerciales, la información generada durante llamadas, reuniones o visitas debe registrarse posteriormente de forma manual en un CRM.

Este proceso puede provocar:

- Pérdida de tiempo en tareas administrativas.
- Retrasos en el registro de información.
- Pérdida de contexto.
- Datos incompletos o inconsistentes.
- Fricción en situaciones de movilidad.

CRMVoice plantea una alternativa: permitir que el usuario registre la información directamente mediante **lenguaje natural y voz**.

---

## 🚀 Solución

El flujo principal de CRMVoice transforma una grabación de voz en un registro estructurado dentro del sistema:

```text
Usuario
   │
   ▼
Grabación de voz
   │
   ▼
Whisper (ASR)
   │
   ▼
Transcripción
   │
   ▼
OpenAI / NLP
   │
   ▼
Extracción y estructuración de información
   │
   ▼
Validación y resolución de entidades
   │
   ▼
Revisión del usuario
   │
   ▼
Registro estructurado en CRM
```

Por ejemplo, a partir de una frase comercial expresada en lenguaje natural, el sistema puede identificar información relevante como el cliente, contacto, tipo de actividad, productos, fechas o descripción y convertirla en datos estructurados.

Antes de guardar definitivamente la información, el usuario puede **revisar, corregir o completar los datos detectados**.

---

## ✨ Funcionalidades principales

- 🎙️ Registro de actividades comerciales mediante voz.
- 📝 Transcripción automática de audio con Whisper.
- 🧠 Procesamiento de lenguaje natural mediante OpenAI.
- 🔎 Extracción automática de información comercial.
- 👤 Registro, inicio de sesión y autenticación de usuarios.
- 📊 Gestión de actividades dentro del entorno CRM.
- 🔍 Consulta y filtrado del histórico de actividades.
- ✏️ Edición y eliminación de registros.
- 📅 Visualización y gestión de actividades mediante calendario.
- 🤖 Asistente inteligente para consultar información almacenada.
- 📱 Interfaz multiplataforma desarrollada con Flutter.

---

## 🏗️ Arquitectura

CRMVoice utiliza una arquitectura modular dividida en cuatro bloques principales:

### Frontend

Aplicación desarrollada con **Flutter**, encargada de la interfaz de usuario y de la interacción con las distintas funcionalidades del sistema.

### Backend

API REST desarrollada con **FastAPI y Python**, responsable de:

- Lógica de negocio.
- Autenticación.
- Gestión de actividades.
- Comunicación con la base de datos.
- Procesamiento de audio.
- Integración con los servicios de inteligencia artificial.

### Inteligencia artificial

El procesamiento se realiza desde el backend mediante:

- **Whisper** → reconocimiento automático del habla (ASR).
- **OpenAI** → interpretación, procesamiento NLP y estructuración de la información.

La IA no se ejecuta directamente desde el frontend.

### Base de datos

Se utiliza **SQLite** como sistema de persistencia mediante un modelo relacional centrado en las actividades comerciales y sus entidades relacionadas.

---

## 🛠️ Tecnologías utilizadas

### Frontend
- Flutter
- Dart

### Backend
- Python
- FastAPI
- REST API

### Inteligencia artificial
- Whisper
- OpenAI API
- Automatic Speech Recognition (ASR)
- Natural Language Processing (NLP)

### Base de datos
- SQLite

### Seguridad
- Autenticación mediante JWT

### Herramientas
- Git
- GitHub
- Visual Studio Code
- Trello

---

## 📁 Estructura del proyecto

```text
CRMVoice/
│
├── frontend/        # Aplicación multiplataforma Flutter
├── backend/         # API REST con FastAPI y Python
└── docs/            # Documentación del proyecto
```

El frontend se comunica con el backend mediante una API REST. El backend centraliza la lógica de negocio, el acceso a datos y las integraciones con los servicios de inteligencia artificial.

---

## 🗃️ Modelo de datos

El modelo relacional está centrado en la entidad **Activity**, que representa las actividades comerciales registradas en el CRM.

Las actividades se relacionan con diferentes entidades del dominio, entre ellas:

- Usuarios.
- Clientes.
- Contactos.
- Productos.
- Tipos de actividad.

El sistema permite almacenar, consultar y gestionar posteriormente la información estructurada obtenida a partir del procesamiento de voz.

---

## 🧪 Pruebas y validación

El prototipo fue validado mediante pruebas funcionales y pruebas específicas sobre el flujo de procesamiento ASR/NLP.

### Pruebas funcionales

Se realizaron **15 pruebas funcionales** sobre las principales características del sistema:

- Autenticación.
- Grabación de audio.
- Generación automática de actividades.
- Operaciones CRUD.
- Histórico y filtros.
- Calendario.
- Asistente inteligente.

**Resultado: 15/15 pruebas funcionales superadas.**

### Validación ASR/NLP

También se realizaron **5 pruebas específicas** utilizando frases comerciales expresadas en lenguaje natural:

- **4** procesadas completamente de forma correcta.
- **1** procesada parcialmente de forma correcta debido a una imprecisión en un nombre propio.

Esto supuso aproximadamente un **80 % de acierto completo** dentro de esta validación preliminar del prototipo.

---

## ⚠️ Limitaciones y posibles mejoras

CRMVoice se desarrolló como un prototipo funcional y existen diferentes líneas de evolución:

- Mejorar el reconocimiento de nombres propios y expresiones específicas.
- Ampliar las pruebas ASR con diferentes acentos, ruido y escenarios comerciales.
- Reducir la dependencia de servicios externos mediante modelos locales o arquitecturas híbridas.
- Continuar mejorando la adaptación responsive de determinadas vistas, especialmente el calendario.
- Integrar el sistema con plataformas CRM reales como Salesforce, HubSpot o Zoho mediante APIs externas.
- Preparar la arquitectura para entornos productivos de mayor escala.

---

## 🎓 Contexto académico

CRMVoice fue desarrollado como **Trabajo Fin de Grado del Grado en Ingeniería Informática** en la Universidad Católica San Antonio de Murcia (UCAM).

El objetivo del proyecto fue estudiar y validar la viabilidad técnica de integrar reconocimiento de voz e inteligencia artificial dentro de un entorno CRM para automatizar el registro estructurado de actividades comerciales.

---

## 👨‍💻 Autor

**Juan Marín Escolano**

Ingeniería Informática — UCAM  
2026
