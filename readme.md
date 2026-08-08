# 🚀 Plataforma de Gestión de Reservas sobre Incus

**Enfoque:** Infraestructura como Código (IaC), Automatización, Observabilidad y Microservicios.

---

## 📋 Descripción del Proyecto

El objetivo de este laboratorio es desplegar un entorno distribuido reproducible, ligero y de bajo consumo utilizando **Incus** como motor de contenedores. La plataforma implementa un sistema de gestión de reservas académicas compuesto por microservicios desacoplados (API Gateway, Backend de lógica de negocio, Base de datos y Monitoreo).

### Requerimientos Mínimos de Hardware
* **Procesador:** 4 núcleos con virtualización habilitada.
* **Memoria RAM:** 8 GB como base para el escenario mínimo.
* **Almacenamiento:** SSD de 256 GB (preferiblemente NVMe).
* **Sistema Operativo Base:** Linux Ubuntu 22.04 LTS o superior (el usuario debe pertenecer al grupo `sudo`).

---

## ⚡ Puesta en Marcha (UN SOLO COMANDO)

El despliegue está diseñado para ejecutarse en un **Ubuntu recién instalado** sin pasos manuales: el propio script detecta las dependencias faltantes (Incus, OpenTofu, Ansible), las instala, prepara los permisos y el entorno, y despliega toda la plataforma.

```bash
sudo apt-get install -y git curl   # solo herramientas base
git clone https://github.com/zfrkx/Proyecto-Reservas.git
cd Proyecto-Reservas
./deploy.sh
```

> ⚠️ **Importante:** ejecuta `./deploy.sh` como **usuario normal** (sin `sudo`). El script solicita credenciales de `sudo` internamente cuando las necesita (instalación de paquetes y acceso inicial al daemon de Incus). Ejecutarlo como root rompe la propiedad de los archivos de estado.

### ¿Qué hace `deploy.sh`?

```text
Usuario normal (Ubuntu limpio)
    ↓ ejecuta ./deploy.sh
    ↓ setup-host.sh instala/verifica Incus, OpenTofu, Ansible y la red (idempotente)
    ↓ [1/3] OpenTofu: init + apply → 4 contenedores en `red-reservas`
    ↓ [2/3] Ansible: configura PostgreSQL, Backend Flask, Nginx y Monitoreo
    ↓ [3/3] Smoke test: verifica que el API Gateway responde HTTP 200
    ↓ despliegue exitoso
```

* **Idempotente:** puede ejecutarse varias veces; la segunda ejecución detecta que todo está en orden y no cambia nada.
* **Acceso a Incus sin root:** cuando la sesión no tiene aún el grupo `incus-admin` activo (típico en instalaciones nuevas), OpenTofu/Incus/Ansible se ejecutan con el grupo añadido vía `setpriv` manteniendo la propiedad de los archivos en tu usuario.
* Los mensajes de grafana/API se muestran al final de la ejecución.

### Estructura del Repositorio

```text
.
├── ansible/
│   ├── deploy-api.yml          # Configuración de Nginx como Proxy Inverso (app-api)
│   ├── deploy-core.yml         # Configuración del servicio Backend Flask (app-core)
│   ├── deploy-db.yml           # Aprovisionamiento de PostgreSQL (db-postgres)
│   ├── deploy-monitoring.yml   # Aprovisionamiento de Prometheus y Grafana (monitoring)
│   ├── files/
│   │   ├── app.py              # Código fuente de la aplicación Flask
│   │   └── grafana/            # Dashboards y proveedor de Grafana
│   ├── inventory.ini           # Inventario de hosts e IPs de Ansible
│   ├── setup.yml               # Playbook de preparación base
│   └── site.yml                # Master Playbook (Orquestación general)
├── deploy.sh                   # Script maestro de despliegue automatizado y Smoke Test
├── setup-host.sh               # Bootstrapper: Instala Incus, OpenTofu, Ansible, red y storage
└── tofu/
    ├── main.tf                 # Definición de infraestructura en código (IaC)
    ├── .terraform.lock.hcl     # Bloqueo de dependencias (versionado)
    └── terraform.tfstate*      # Estado local (NO se versiona, se regenera)
```

`tofu/terraform.tfstate`, `.terraform/` y `.tofu/` son generados localmente por OpenTofu y están ignorados por git (`*.tfstate`, `.terraform/`).

---

## 🏗️ Arquitectura de Nodos y Red

Todos los nodos operan dentro de la red privada `red-reservas` (`10.10.0.0/24`):

| Nodo | IP Estática | Función / Microservicio | Tecnología |
| :--- | :--- | :--- | :--- |
| **`db-postgres`** | `10.10.0.95` | Persistencia (Usuarios, Recursos, Reservas) | PostgreSQL 14 |
| **`app-core`** | `10.10.0.96` | Lógica de negocio y reglas del sistema | Python (Flask) + Systemd |
| **`app-api`** | `10.10.0.97` | API Gateway / Punto de entrada REST | Nginx (Proxy Inverso) |
| **`monitoring`** | `10.10.0.98` | Recolección de métricas y visualización | Prometheus + Grafana |

---

## 🌐 API REST (comandos `curl`)

El **punto de entrada único** es el API Gateway: `http://10.10.0.97` (Nginx reenvía todo al backend en `app-core:5000`).

### 📌 Recursos

```bash
# Listar todos los recursos
curl http://10.10.0.97/recursos

# Crear un recurso
curl -X POST http://10.10.0.97/recursos \
     -H "Content-Type: application/json" \
     -d '{"nombre":"Aula 101","tipo":"salón"}'
```

Respuesta esperada al crear:

```json
{"mensaje": "Recurso creado", "id": 1}
```

### 🗓️ Reservas

```bash
# Listar todas las reservas
curl http://10.10.0.97/reservas

# Crear una reserva (fecha en formato AAAA-MM-DD)
curl -X POST http://10.10.0.97/reservas \
     -H "Content-Type: application/json" \
     -d '{"recurso_id": 1, "usuario": "maria", "fecha": "2026-08-10"}'
```

Respuesta esperada:

```json
{"mensaje": "Reserva creada", "id": 1}
```

> Si el `recurso_id` no existe o los datos son inválidos, la API responde `400` con `{"error": "Recurso no existe o datos inválidos"}`.

### 📊 Métricas (Prometheus)

```bash
# Métricas del backend expuestas en formato Prometheus
curl http://10.10.0.97/metrics
```

### 🧪 Smoke test manual

```bash
# Comprobar el estado del API Gateway (código 200 = todo OK)
curl -s -o /dev/null -w '%{http_code}\n' http://10.10.0.97/recursos
```

---

## 📈 Acceso a Monitoreo

* **Grafana:** http://10.10.0.98:3000 (dashboard de reservas auto-provisionado)
* **Prometheus:** http://10.10.0.98:9090 (scraping de métricas de los microservicios)

---

## ⚙️ Cumplimiento de Requerimientos del Sistema

| Código | Requerimiento | Estado | Implementación en la Solución |
| :--- | :--- | :---: | :--- |
| **RF-01** | Instancias Incus con nombres e IPs estáticas | ✅ | Definidas mediante **OpenTofu** (`tofu/main.tf`). |
| **RF-02** | Red segmentada para comunicación entre servicios | ✅ | Subred virtual `red-reservas` (`10.10.0.0/24`). |
| **RF-03** | Automatización total con OpenTofu y Ansible | ✅ | Scripts `setup-host.sh`, `deploy.sh` y Playbooks Ansible. |
| **RF-04** | Recolección de métricas y visualización | ✅ | Métricas scrabeadas por **Prometheus** y visualizadas en **Grafana**. |