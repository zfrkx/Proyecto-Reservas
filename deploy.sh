#!/bin/bash
# =============================================================================
# deploy.sh
# Despliegue maestro idempotente de la plataforma de reservas.
# - Detecta dependencias e invoca setup-host.sh si falta alguna.
# - Aprovisiona la infraestructura (OpenTofu), configura servicios (Ansible)
#   y ejecuta una prueba de humo (smoke test).
# Funciona desde cualquier directorio y puede ejecutarse varias veces.
#
# Uso: ./deploy.sh   (desde cualquier directorio)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$PATH:/usr/local/bin"

# --- Utilidades de mensajes ---------------------------------------------------
RESET='\033[0m'; RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'
info() { printf "${BLUE}[INFO]${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}[OK]${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
err()  { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "Fallo inesperado en la línea ${LINENO}: ${BASH_COMMAND}"' ERR

# --- Privilegios --------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# --- Entorno de Ansible (venv creado por setup-host.sh) ------------------------
ANSIBLE_VENV="${HOME}/.local/share/reservas/ansible-venv"
ANSIBLE_PLAYBOOK="${ANSIBLE_VENV}/bin/ansible-playbook"
ANSIBLE_HOME="${ANSIBLE_VENV}/ansible-home"

# 1. Verificar toolchain; si falta algo, ejecutar el bootstrapper
needs_setup=0
[ -x "$ANSIBLE_PLAYBOOK" ]      || needs_setup=1
command -v tofu >/dev/null 2>&1 || needs_setup=1
command -v incus >/dev/null 2>&1 || needs_setup=1
command -v curl  >/dev/null 2>&1 || needs_setup=1

if [ "$needs_setup" -eq 1 ]; then
    info "Faltan dependencias en el host. Ejecutando automatización de entorno..."
    bash "$SCRIPT_DIR/setup-host.sh"
fi

# Re-verificación tras el setup (se detiene con un mensaje claro)
[ -x "$ANSIBLE_PLAYBOOK" ] || die "Ansible no está disponible tras el setup. Revisa setup-host.sh."
command -v tofu >/dev/null 2>&1 || die "OpenTofu (tofu) no está disponible tras el setup. Revisa setup-host.sh."
command -v incus >/dev/null 2>&1 || die "Incus no está disponible tras el setup. Revisa setup-host.sh."

# 2. Acceso al daemon de Incus
CMD_PREFIX=""
if incus info >/dev/null 2>&1; then
    ok "Acceso al daemon de Incus disponible sin sudo."
else
    [ -n "$SUDO" ] || die "Sin acceso al daemon de Incus y sin sudo disponible."
    warn "El usuario actual no tiene acceso directo a Incus. Se usará sudo automáticamente."
    CMD_PREFIX="$SUDO"
fi
TOFU_CMD="$(command -v tofu)"

echo "===================================================="
info "DESPLEGANDO PLATAFORMA DISTRIBUIDA DE RESERVAS"
echo "===================================================="

# 3. [1/3] Aprovisionar infraestructura con OpenTofu
info "[1/3] Aprovisionando infraestructura con OpenTofu..."
cd "$SCRIPT_DIR/tofu"
$CMD_PREFIX "$TOFU_CMD" init -input=false

# Calentar la caché de imágenes de incusd antes del apply concurrente.
# La caché de simple streams (/var/cache/incus/<sha256 del remote>) se crea en
# ConnectSimpleStreams (incus: client/connection.go) con un check-then-mkdir NO
# atómico. Cuando se crean los 4 contenedores en paralelo y la caché aún no
# existe, los os.Mkdir concurrentes chocan con "mkdir ...: file exists" y la
# creación de alguna instancia falla de forma intermitente.
# Una única descarga previa crea la caché y deja la imagen en el almacén local,
# de modo que el apply reutiliza la copia local sin descargas remotas en paralelo.
if command -v incus >/dev/null 2>&1; then
    if $CMD_PREFIX incus image info ubuntu-22.04 >/dev/null 2>&1; then
        ok "Imagen local ubuntu-22.04 ya disponible (caché calentada)."
    elif $CMD_PREFIX incus image copy "images:ubuntu/22.04" local: --alias "ubuntu-22.04" >/dev/null 2>&1; then
        ok "Caché de imágenes calentada (imagen local: ubuntu-22.04)."
    else
        warn "No se pudo calentar la caché de imágenes; el apply reintentará la descarga remota."
    fi
fi

$CMD_PREFIX "$TOFU_CMD" apply -auto-approve
# Si se usó sudo, devolver la propiedad de los archivos de estado al usuario
# para mantener la idempotencia entre ejecuciones.
if [ -n "$CMD_PREFIX" ]; then
    "$SUDO" chown -R "$(id -un)" "$SCRIPT_DIR/tofu" 2>/dev/null || true
fi
cd "$SCRIPT_DIR"
ok "Infraestructura aprovisionada."

# 4. [2/3] Configurar servicios con Ansible
info "[2/3] Configurando servicios con Ansible..."

# Esperar a que los 4 contenedores estén ejecutándose y accesibles
wait_for_containers() {
    local names=(app-api app-core db-postgres monitoring)
    local i=0 attempts=60
    while [ "$i" -lt "$attempts" ]; do
        i=$((i + 1))
        local all_ready=1
        for n in "${names[@]}"; do
            if ! $CMD_PREFIX incus exec "$n" -- true >/dev/null 2>&1; then
                all_ready=0
                break
            fi
        done
        if [ "$all_ready" -eq 1 ]; then
            ok "Los 4 contenedores están ejecutándose."
            return 0
        fi
        sleep 2
    done
    warn "Los contenedores no respondieron a tiempo; continuando igualmente con Ansible."
}
wait_for_containers

run_ansible() {
    if [ -n "$CMD_PREFIX" ]; then
        "$SUDO" env ANSIBLE_HOME="$ANSIBLE_HOME" ANSIBLE_COLLECTIONS_PATH="$ANSIBLE_VENV/collections" \
            "$ANSIBLE_PLAYBOOK" -i "$SCRIPT_DIR/ansible/inventory.ini" "$SCRIPT_DIR/ansible/site.yml"
    else
        env ANSIBLE_HOME="$ANSIBLE_HOME" ANSIBLE_COLLECTIONS_PATH="$ANSIBLE_VENV/collections" \
            "$ANSIBLE_PLAYBOOK" -i "$SCRIPT_DIR/ansible/inventory.ini" "$SCRIPT_DIR/ansible/site.yml"
    fi
}
run_ansible

# Restaurar propiedad de archivos generados por Ansible cuando se usó sudo
if [ -n "$CMD_PREFIX" ]; then
    "$SUDO" chown -R "$(id -un)" "$ANSIBLE_HOME" 2>/dev/null || true
fi
ok "Servicios configurados con Ansible."

# 5. [3/3] Prueba de humo (smoke test) con reintentos
info "[3/3] Ejecutando prueba de humo (smoke test)..."
SMOKE_URL="${SMOKE_URL:-http://10.10.0.97/recursos}"
http_code="000"
i=0
while [ "$i" -lt 12 ]; do
    i=$((i + 1))
    http_code="$(curl -s -o /dev/null -w '%{http_code}' "$SMOKE_URL" || true)"
    [ "$http_code" = "200" ] && break
    [ "$i" -lt 12 ] && sleep 10
done

if [ "$http_code" = "200" ]; then
    ok "Prueba de humo superada: el API Gateway ($SMOKE_URL) responde HTTP 200."
else
    warn "Prueba de humo fallida (HTTP ${http_code}). Revisa los servicios."
fi

echo "===================================================="
echo " Grafana: http://10.10.0.98:3000"
echo " API Gateway: http://10.10.0.97/recursos"
echo "===================================================="
