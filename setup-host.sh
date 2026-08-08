#!/bin/bash
# =============================================================================
# setup-host.sh
# Bootstrap idempotente del host: Incus, OpenTofu, Ansible y red interna.
# Diseñado para equipos nuevos: no asume dependencias, configuraciones ni
# rutas previas. Puede ejecutarse varias veces sin romper nada.
#
# Uso: ./setup-host.sh   (desde cualquier directorio)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Utilidades de mensajes ---------------------------------------------------
RESET='\033[0m'; RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'
info() { printf "${BLUE}[INFO]${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}[OK]${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
err()  { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "Fallo inesperado en la línea ${LINENO}: ${BASH_COMMAND}"' ERR

# --- Detectar usuario y privilegios -------------------------------------------
# El script se ejecuta como usuario normal; solo las operaciones de sistema
# usan sudo. No se fuerza root salvo cuando es imprescindible.
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    RUN_USER="${SUDO_USER:-root}"
else
    command -v sudo >/dev/null 2>&1 || die "Se requiere sudo y no está disponible. Ejecuta como root o instala sudo."
    SUDO="sudo"
    RUN_USER="${USER:-$(id -un)}"
fi

command -v apt-get >/dev/null 2>&1 || die "Este script requiere una distribución basada en Debian/Ubuntu (apt-get)."

echo "===================================================="
info "PREPARANDO ENTORNO BASE (INCUS, OPENTOFU, ANSIBLE)"
echo "===================================================="

# 1. Limpiar restos de instalaciones previas de OpenTofu por APT (evitan errores)
$SUDO rm -f /etc/apt/sources.list.d/opentofu.list /etc/apt/sources.list.d/opentofu-repo.list

# 2. Dependencias base del sistema
info "Actualizando repositorios e instalando dependencias del sistema..."
$SUDO apt-get update -qq
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget gnupg git ca-certificates lsb-release software-properties-common \
    python3 python3-venv python3-pip
ok "Dependencias del sistema instaladas."

# 3. Incus
if ! command -v incus >/dev/null 2>&1; then
    info "Incus no está instalado. Añadiendo el repositorio Zabbly..."

    APT_CODENAME=""
    if [ -f /etc/os-release ]; then
        APT_CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    fi
    [ -n "$APT_CODENAME" ] || APT_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
    [ -n "$APT_CODENAME" ] || die "No se pudo determinar el nombre en clave (codename) de la distribución."
    ARCH="$(dpkg --print-architecture)"

    $SUDO mkdir -p /etc/apt/keyrings
    $SUDO curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
    "$SUDO" tee /etc/apt/sources.list.d/zabbly-incus-stable.sources >/dev/null <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: ${APT_CODENAME}
Components: main
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF

    info "Instalando Incus..."
    $SUDO apt-get update -qq
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y incus incus-client
    ok "Incus instalado."
else
    ok "Incus ya está instalado ($(incus version 2>/dev/null | head -n1 || true))."
fi

# Agregar al usuario actual al grupo 'incus-admin' (acceso a Incus sin sudo)
if getent group incus-admin >/dev/null 2>&1; then
    if [ -n "$RUN_USER" ] && [ "$RUN_USER" != "root" ]; then
        if ! id -nG "$RUN_USER" | tr ' ' '\n' | grep -qx incus-admin; then
            info "Agregando '${RUN_USER}' al grupo 'incus-admin'..."
            $SUDO usermod -aG incus-admin "$RUN_USER"
            warn "El cambio de grupo aplica en una nueva sesión. El despliegue usará sudo automáticamente mientras tanto."
        fi
    fi
fi

# Inicializar el daemon de Incus (solo si no está inicializado)
if ! $SUDO incus admin init --dump >/dev/null 2>&1; then
    info "Inicializando el daemon de Incus (configuración mínima)..."
    $SUDO incus admin init --minimal
    ok "Daemon de Incus inicializado."
else
    ok "Daemon de Incus ya inicializado."
fi

# Red interna 'red-reservas' (10.10.0.0/24) con NAT saliente para los contenedores
if ! $SUDO incus network show red-reservas >/dev/null 2>&1; then
    info "Creando red interna 'red-reservas' (10.10.0.0/24)..."
    $SUDO incus network create red-reservas \
        ipv4.address=10.10.0.1/24 \
        ipv4.dhcp=true \
        ipv4.nat=true \
        ipv6.address=auto
    ok "Red 'red-reservas' creada."
else
    ok "Red 'red-reservas' ya existe."
    # Garantizar NAT IPv4 (necesario para que los contenedores instalen paquetes)
    if ! $SUDO incus network show red-reservas | grep -q 'ipv4.nat: "true"'; then
        info "Habilitando NAT IPv4 en 'red-reservas'..."
        $SUDO incus network set red-reservas ipv4.nat=true
    fi
fi

# Storage pool + disco raíz en el perfil 'default'.
# En hosts recién instalados, el daemon puede quedar inicializado SIN storage
# pool ni perfil con disco raíz; sin ellos, Incus falla al crear cualquier
# contenedor con "Failed detecting root disk device: No root device could be
# found" (el driver 'dir' siempre está disponible, sin módulos del kernel).
STORAGE_POOL="$($SUDO incus storage list --format csv 2>/dev/null | head -n1 | cut -d, -f1)"
if [ -z "$STORAGE_POOL" ]; then
    info "Creando storage pool 'default' (driver dir)..."
    $SUDO incus storage create default dir
    STORAGE_POOL="default"
else
    ok "Storage pool '${STORAGE_POOL}' ya existe."
fi
if ! $SUDO incus profile device list default 2>/dev/null | grep -qx 'root'; then
    info "Añadiendo disco raíz al perfil 'default'..."
    $SUDO incus profile device add default root disk path=/ pool="$STORAGE_POOL"
    ok "Perfil 'default' configurado con disco raíz."
else
    ok "El perfil 'default' ya tiene su disco raíz."
fi

# 4. OpenTofu (binario standalone; funciona en cualquier versión de Linux)
if ! command -v tofu >/dev/null 2>&1; then
    info "Instalando OpenTofu (binario standalone)..."
    INSTALLER="$(mktemp)"
    curl -fsSL https://get.opentofu.org/install-opentofu.sh -o "$INSTALLER"
    chmod +x "$INSTALLER"
    # IMPORTANTE: el instalador de OpenTofu extrae la huella GPG del release
    # usando 'grep "Primary key fingerprint:"'. gpg traduce esa línea según el
    # locale del sistema (ej. es_ES.UTF-8 -> "Huellas dactilares de la clave
    # primaria:"), por lo que la verificación falla con "The release is signed
    # with the incorrect key: ." en equipos con locale distinto a C/inglés.
    # Forzar LC_ALL=C garantiza salida en inglés y una instalación correcta.
    $SUDO env LC_ALL=C LANG=C LC_MESSAGES=C "$INSTALLER" --install-method standalone
    rm -f "$INSTALLER"
    # Ubicación estándar para evitar depender de /usr/local/bin en el PATH
    if [ -x /usr/local/bin/tofu ] && [ ! -e /usr/bin/tofu ]; then
        $SUDO ln -s /usr/local/bin/tofu /usr/bin/tofu
    fi
    command -v tofu >/dev/null 2>&1 || die "La instalación de OpenTofu falló."
    ok "OpenTofu instalado ($(tofu version 2>/dev/null | head -n1 || true))."
else
    ok "OpenTofu ya está instalado ($(tofu version 2>/dev/null | head -n1 || true))."
fi

# 5. Ansible moderno en un entorno aislado por usuario (venv).
#    El paquete 'ansible' de APT en Ubuntu 22.04 es 2.10, incompatible con las
#    colecciones que requieren los playbooks (community.general >= 8.2 / incus).
#    Un venv propio garantiza una versión compatible en 22.04, 24.04 y 26.04.
ANSIBLE_VENV="${HOME}/.local/share/reservas/ansible-venv"
info "Preparando entorno aislado de Ansible en ${ANSIBLE_VENV}..."
if [ ! -d "$ANSIBLE_VENV" ]; then
    mkdir -p "$(dirname "$ANSIBLE_VENV")"
    python3 -m venv "$ANSIBLE_VENV"
fi
# Garantizar pip dentro del venv (Ubuntu puede deshabilitar ensurepip)
if ! "$ANSIBLE_VENV/bin/python" -m pip --version >/dev/null 2>&1; then
    "$ANSIBLE_VENV/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
fi
"$ANSIBLE_VENV/bin/python" -m pip install --quiet --upgrade pip
"$ANSIBLE_VENV/bin/python" -m pip install --quiet "ansible-core>=2.14"
"$ANSIBLE_VENV/bin/ansible-galaxy" collection install --upgrade \
    --collections-path "$ANSIBLE_VENV/collections" \
    community.general community.postgresql
ok "Ansible listo ($("$ANSIBLE_VENV/bin/ansible" --version 2>/dev/null | head -n1 || true))."

echo "===================================================="
ok "ENTORNO BASE PREPARADO EXITOSAMENTE."
echo "===================================================="
if ! incus info >/dev/null 2>&1 && [ -n "$SUDO" ]; then
    warn "El grupo 'incus-admin' aplica en una nueva sesión. No es necesario reingresar:"
    warn "deploy.sh ejecutará OpenTofu/Incus/Ansible como tu usuario con el grupo añadido (setpriv), sin generar archivos como root."
fi
