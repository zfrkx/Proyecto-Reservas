cat << 'EOF' > deploy.sh
#!/bin/bash
set -e

# Verificación de herramientas clave
if ! command -v incus &> /dev/null || ! command -v tofu &> /dev/null || ! command -v ansible &> /dev/null; then
    echo "[!] Faltan dependencias en el host. Ejecutando automatización de entorno..."
    ./setup-host.sh
fi

echo "===================================================="
echo " DESPLEGANDO PLATAFORMA DISTRIBUIDA DE RESERVAS"
echo "===================================================="

echo "[1/3] Aprovisionando Infraestructura con OpenTofu..."
cd tofu
tofu init -input=false
tofu apply -auto-approve
cd ..

echo "[2/3] Configurando Servicios con Ansible..."
# Esperar que los contenedores obtengan IP e interfaz lista
sleep 3
ansible-playbook -i ansible/inventory.ini ansible/site.yml

echo "[3/3] Ejecutando Prueba de Humo (Smoke Test)..."
sleep 2
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://10.10.0.97/recursos || echo "000")

if [ "$HTTP_STATUS" -eq 200 ]; then
    echo " ¡Despliegue Exitoso! El API Gateway (10.10.0.97) responde correctamente."
else
    echo "❌ Alerta: La prueba de humo falló con código HTTP $HTTP_STATUS."
fi

echo "===================================================="
echo " Grafana: http://10.10.0.98:3000"
echo " API Gateway: http://10.10.0.97/recursos"
echo "===================================================="
EOF

chmod +x deploy.sh
