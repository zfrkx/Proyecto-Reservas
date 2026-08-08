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
# Diseño: deploy.sh SIEMPRE se ejecuta como usuario normal. Las operaciones
# que requieren privilegios (acceso al socket del daemon de Incus, reparación
# de propiedad) se realizan de forma puntual con sudo, sin cambiar nunca el
# propietario de los archivos de estado.
if [ "$(id -u)" -eq 0 ]; then
    die "No ejecutes deploy.sh como root. Ejecútalo como usuario normal; el script usa sudo internamente cuando es necesario."
fi
SUDO="sudo"
RUN_USER="$(id -un)"
RUN_UID="$(id -u)"
RUN_GID="$(id -g)"

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

# 2. Acceso al daemon de Incus --------------------------------------------------
# El socket del daemon (/var/lib/incus/unix.socket) solo permite el acceso a
# root o al grupo incus-admin. En un equipo recién instalado, setup-host.sh
# agrega al usuario al grupo en la MISMA ejecución, pero la sesión actual aún
# no tiene el grupo cargado y `incus info` falla.
# Estrategia (OpenTofu/Incus/Ansible NUNCA se ejecutan como root):
#   direct  -> la sesión ya tiene el grupo activo (ej. re-login). Todo corre
#              como usuario normal y los archivos de estado quedan del usuario.
#   setpriv -> sesión sin el grupo activo. Se ejecuta el MISMO usuario con
#              incus-admin añadido a los grupos suplementarios mediante
#              `sudo setpriv --reuid/--regid/--groups`. Root solo existe el
#              instante de lanzar el comando: los archivos que generan tofu,
#              incus y ansible siguen siendo propiedad del usuario.
#   sudo    -> contingencia si setpriv no existe. Se ejecuta con sudo y se
#              restaura de inmediato la propiedad al usuario, incluso si el
#              comando falla (ver run_as_user).
INCUS_CMD="$(command -v incus)"
TOFU_CMD="$(command -v tofu)"
STATE_DIR="$SCRIPT_DIR/tofu"

INCUS_GROUP="incus-admin"
INCUS_GID="$(getent group "$INCUS_GROUP" 2>/dev/null | cut -d: -f3 || true)"

INCUS_MODE="direct"
if ! "$INCUS_CMD" info >/dev/null 2>&1; then
    if [ -n "$INCUS_GID" ] && command -v setpriv >/dev/null 2>&1; then
        INCUS_MODE="setpriv"
        # Grupos suplementarios = grupos reales de esta sesión + incus-admin
        # (id -G refleja los grupos de la sesión, sin el grupo recién añadido;
        # se construye la lista manualmente y se deduplican los repetidos).
        EXTRA_GROUPS="$(printf '%s\n' "$(id -G)" "$INCUS_GID" | awk 'NF && !seen[$0]++' | paste -sd, -)"
        warn "Sesión sin el grupo '${INCUS_GROUP}' activo: se usará setpriv para ejecutar con el grupo añadido (sin archivos como root)."
    else
        INCUS_MODE="sudo"
        warn "Sin acceso directo a Incus y sin setpriv disponible: se usará sudo y se restaurará la propiedad de los archivos."
    fi
else
    ok "Acceso al daemon de Incus disponible sin sudo."
fi

# run_as_user: ejecuta $@ con acceso al daemon de Incus, PERO siempre como el
# usuario normal (nunca como root), de modo que los archivos que generan
# OpenTofu, Incus o Ansible pertenezcan al usuario que ejecuta el despliegue.
run_as_user() {
    if [ "$INCUS_MODE" = "direct" ]; then
        "$@"
    elif [ "$INCUS_MODE" = "setpriv" ]; then
        "$SUDO" env HOME="$HOME" USER="$RUN_USER" LOGNAME="$RUN_USER" \
            XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}" \
            setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --groups="$EXTRA_GROUPS" "$@"
    else
        # Modo de contingencia: devolver la propiedad al usuario INMEDIATAMENTE
        # después del comando, incluso si este falla (evita dejar estado root).
        if ! "$SUDO" env HOME="$HOME" USER="$RUN_USER" LOGNAME="$RUN_USER" "$@"; then
            "$SUDO" chown -R "$RUN_USER" "$STATE_DIR" 2>/dev/null || true
            return 1
        fi
        "$SUDO" chown -R "$RUN_USER" "$STATE_DIR" 2>/dev/null || true
    fi
}

# normalize_ownership: invariante del proyecto. Los artefactos de estado
# (OpenTofu, Ansible, configuración del cliente incus) deben pertenecer
# SIEMPRE al usuario que despliega. Repara automáticamente estados heredados
# de versiones anteriores o de ejecuciones privilegiadas interrumpidas, sin
# requerir pasos manuales.
normalize_ownership() {
    local d
    for d in "$STATE_DIR" "$ANSIBLE_HOME" "$HOME/.config/incus"; do
        if [ -e "$d" ] && find "$d" -user root -print -quit 2>/dev/null | grep -q .; then
            warn "Reasignando propiedad de '$d' a '$RUN_USER' (artefacto de una ejecución privilegiada)..."
            "$SUDO" chown -R "$RUN_USER" "$d" 2>/dev/null || true
        fi
    done
}

# 2b. Verificar que Incus puede crear instancias (storage pool + disco raíz).
# En hosts recién instalados el daemon puede responder sin storage pool ni
# perfil con disco raíz; en ese estado Incus falla al crear contenedores con
# "No root device could be found". setup-host.sh garantiza ambos de forma
# idempotente, así que se completa el bootstrap cuando hacen falta.
if ! run_as_user "$INCUS_CMD" storage list --format csv 2>/dev/null | grep -q . \
   || ! run_as_user "$INCUS_CMD" profile device list default 2>/dev/null | grep -qx 'root'; then
    warn "El host Incus no tiene storage pool ni disco raíz en el perfil 'default'. Completando inicialización..."
    bash "$SCRIPT_DIR/setup-host.sh"
fi

echo "===================================================="
info "DESPLEGANDO PLATAFORMA DISTRIBUIDA DE RESERVAS"
echo "===================================================="

# 3. [1/3] Aprovisionar infraestructura con OpenTofu
info "[1/3] Aprovisionando infraestructura con OpenTofu..."
cd "$STATE_DIR"
normalize_ownership
run_as_user "$TOFU_CMD" init -input=false

# Calentar la caché de imágenes de incusd antes del apply concurrente.
# La caché de simple streams (/var/cache/incus/<sha256 del remote>) se crea en
# ConnectSimpleStreams (incus: client/connection.go) con un check-then-mkdir NO
# atómico. Cuando se crean los 4 contenedores en paralelo y la caché aún no
# existe, los os.Mkdir concurrentes chocan con "mkdir ...: file exists" y la
# creación de alguna instancia falla de forma intermitente.
# Una única descarga previa crea la caché y deja la imagen en el almacén local,
# de modo que el apply reutiliza la copia local sin descargas remotas en paralelo.
if run_as_user "$INCUS_CMD" image info ubuntu-22.04 >/dev/null 2>&1; then
    ok "Imagen local ubuntu-22.04 ya disponible (caché calentada)."
elif run_as_user "$INCUS_CMD" image copy "images:ubuntu/22.04" local: --alias "ubuntu-22.04" >/dev/null 2>&1; then
    ok "Caché de imágenes calentada (imagen local: ubuntu-22.04)."
else
    warn "No se pudo calentar la caché de imágenes; el apply reintentará la descarga remota."
fi

run_as_user "$TOFU_CMD" apply -auto-approve
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
            if ! run_as_user "$INCUS_CMD" exec "$n" -- true >/dev/null 2>&1; then
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

# El playbook usa el connection plugin community.general.incus (invoca el CLI
# 'incus'), por lo que se ejecuta con el mismo modo de acceso al daemon, pero
# SIEMPRE como el usuario normal: ANSIBLE_HOME y sus archivos son del usuario.
run_ansible() {
    run_as_user env ANSIBLE_HOME="$ANSIBLE_HOME" ANSIBLE_COLLECTIONS_PATH="$ANSIBLE_VENV/collections" \
        "$ANSIBLE_PLAYBOOK" -i "$SCRIPT_DIR/ansible/inventory.ini" "$SCRIPT_DIR/ansible/site.yml"
}
run_ansible
normalize_ownership
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
