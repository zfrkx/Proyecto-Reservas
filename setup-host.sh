cat << 'EOF' > setup-host.sh
#!/bin/bash
set -e

echo "===================================================="
echo " PREPARANDO ENTORNO BASE (INCUS, OPENTOFU, ANSIBLE)"
echo "===================================================="

# 1. Actualizar el sistema e instalar dependencias básicas
sudo apt update && sudo apt install -y curl wget gnupg lsb-release git software-properties-common

# 2. Instalar Incus (Repositorio Oficial Zabbly para Debian/Ubuntu)
if ! command -v incus &> /dev/null; then
    echo "[+] Instalando Incus..."
    sudo mkdir -p /etc/apt/keyrings/
    sudo curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
    sudo sh -c 'cat <<EOT > /etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: '$(lsb_release -cs)'
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOT'
    sudo apt update
    sudo apt install -y incus incus-client
else
    echo "[✔] Incus ya está instalado."
fi

# 3. Agregar el usuario actual al grupo incus-admin
sudo usermod -aG incus-admin "$USER"

# 4. Inicializar Incus de forma no interactiva (si no se ha inicializado)
if ! sudo incus admin state &> /dev/null; then
    echo "[+] Inicializando Incus..."
    sudo incus admin init --minimal
else
    echo "[✔] Incus ya está inicializado."
fi

# 5. Crear la red interna 'red-reservas' con subred 10.10.0.1/24
if ! incus network show red-reservas &> /dev/null; then
    echo "[+] Creando red virtual 'red-reservas'..."
    incus network create red-reservas \
        ipv4.address=10.10.0.1/24 \
        ipv4.dhcp=true \
        ipv6.address=auto
else
    echo "[✔] Red 'red-reservas' ya existe."
fi

# 6. Instalar OpenTofu
if ! command -v tofu &> /dev/null; then
    echo "[+] Instalando OpenTofu..."
    curl -fsSL https://get.opentofu.org/opentofu.gpg | sudo tee /etc/apt/keyrings/opentofu.gpg > /dev/null
    curl -fsSL https://get.opentofu.org/repository.gpg | sudo tee /etc/apt/keyrings/opentofu-repo.gpg > /dev/null
    sudo chmod a+r /etc/apt/keyrings/opentofu.gpg /etc/apt/keyrings/opentofu-repo.gpg
    echo "deb [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/opentofu/any/ any main" | sudo tee /etc/apt/sources.list.d/opentofu.list > /dev/null
    sudo apt update
    sudo apt install -y tofu
else
    echo "[✔] OpenTofu ya está instalado."
fi

# 7. Instalar Ansible
if ! command -v ansible &> /dev/null; then
    echo "[+] Instalando Ansible..."
    sudo apt install -y ansible
else
    echo "[✔] Ansible ya está instalado."
fi

echo "===================================================="
echo " ¡ENTORNO PREPARADO CON ÉXITO!"
echo " Si es la primera vez que instalas Incus, ejecuta:"
echo " newgrp incus-admin"
echo "===================================================="
EOF

chmod +x setup-host.sh
