# 🚀 Plataforma de Gestión de Reservas sobre Incus
**Asignatura:** Sistemas Distribuidos  
**Enfoque:** Infraestructura como Código (IaC), Automatización, Observabilidad y Microservicios.

> 💡 **Regla de Diseño del Proyecto:**  
> *"Todo debe poder reconstruirse desde cero. Si una parte no puede volver a levantarse con scripts, no cuenta como infraestructura académica; cuenta como folklore técnico."*

---

## 📋 Descripción del Proyecto

El objetivo de este laboratorio es desplegar un entorno distribuido reproducible, ligero y de bajo consumo utilizando **Incus** como motor de contenedores. La plataforma implementa un sistema de gestión de reservas académicas compuesto por microservicios desacoplados (API Gateway, Backend de lógica de negocio, Base de datos y Monitoreo).

### Requerimientos Mínimos de Hardware
* **Procesador:** 4 núcleos con virtualización habilitada[cite: 1].
* **Memoria RAM:** 8 GB como base para el escenario mínimo[cite: 1].
* **Almacenamiento:** SSD de 256 GB (preferiblemente NVMe)[cite: 1].
* **Sistema Operativo Base:** Linux Ubuntu 22.04 LTS o superior[cite: 1].

---

## ⚙️ Cumplimiento de Requerimientos del Sistema

| Código | Requerimiento | Estado | Implementación en la Solución |
| :--- | :--- | :---: | :--- |
| **RF-01** | Instancias Incus con nombres e IPs estáticas |  | Definidas mediante **OpenTofu** (`tofu/main.tf`). |
| **RF-02** | Red segmentada para comunicación entre servicios |  | Subred virtual `red-reservas` (`10.10.0.0/24`) en **Incus**[cite: 1]. |
| **RF-03** | Automatización total con OpenTofu y Ansible |  | Scripts `setup-host.sh`, `deploy.sh` y Playbooks Ansible. |
| **RF-04** | Recolección de métricas y visualización |  | Métricas scraped por **Prometheus** y visualizadas en **Grafana**. |

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

## 📂 Estructura Completa del Repositorio

```text
.
├── ansible/
│   ├── deploy-api.yml          # Configuración de Nginx como Proxy Inverso (app-api)
│   ├── deploy-core.yml         # Configuración del servicio Backend Flask (app-core)
│   ├── deploy-db.yml           # Aprovisionamiento de PostgreSQL (db-postgres)
│   ├── deploy-monitoring.yml   # Aprovisionamiento de Prometheus y Grafana (monitoring)
│   ├── files/
│   │   ├── app.py              # Código fuente de la aplicación Flask
│   │   └── grafana/
│   │       ├── dashboards.yaml         # Aprovisionamiento automático del proveedor
│   │       └── reservas-dashboard.json # Tablero visual de métricas de la plataforma
│   ├── inventory.ini           # Inventario de hosts e IPs de Ansible
│   ├── setup.yml               # Playbook de preparación base
│   └── site.yml                # Master Playbook (Orquestación general)
├── deploy.sh                   # Script maestro de despliegue automatizado y Smoke Test
├── setup-host.sh               # Bootstrapper: Instala Incus, OpenTofu, Ansible y crea la red
├── tofu/
│   ├── main.tf                 # Definición de infraestructura en código (IaC)
│   ├── terraform.tfstate       # Estado de la infraestructura en OpenTofu
│   └── terraform.tfstate.backup
└── README.md                   # Documentación técnica del proyecto
