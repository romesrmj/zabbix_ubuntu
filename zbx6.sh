#!/bin/bash

# ==============================
# INSTALAÇÃO ZABBIX 6.4 + APACHE + GRAFANA
# UBUNTU 22.04 LTS
# Versão corrigida e melhorada
# ==============================

set -euo pipefail

# ==============================
# Log de instalação
# ==============================
LOG_FILE="/var/log/zabbix-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=============================="
echo "  Início: $(date)"
echo "=============================="

# ==============================
# Verificação de root
# ==============================
if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Execute como root: sudo $0"
    exit 1
fi

# ==============================
# Verificação de versão do Ubuntu
# ==============================
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "22.04" ]; then
        echo "❌ Este script requer Ubuntu 22.04 LTS."
        echo "   Detectado: ${PRETTY_NAME:-desconhecido}"
        exit 1
    fi
else
    echo "❌ Não foi possível detectar a versão do sistema operacional."
    exit 1
fi

# ==============================
# Atualizar sistema e dependências
# ==============================
echo ""
echo "🛠  Atualizando sistema..."
apt update && apt upgrade -y
apt --fix-broken install -y
dpkg --configure -a
apt autoremove -y
apt autoclean -y

apt install -y snmp snmp-mibs-downloader nano curl wget gnupg2 \
    software-properties-common lsb-release ca-certificates \
    apt-transport-https

# Corrige SNMP para exibir MIBs
if grep -q "^mibs :" /etc/snmp/snmp.conf 2>/dev/null; then
    sed -i 's/^mibs :/# mibs :/' /etc/snmp/snmp.conf
fi

# ==============================
# Configuração do banco de dados
# ==============================
echo ""
echo "=============================="
echo "  CONFIGURAÇÃO DO BANCO DE DADOS"
echo "=============================="

read -p "🧑‍💼 Informe o nome do usuário do banco (ex: zabbix): " DB_USER

# Validação: usuário não pode ser vazio
while [ -z "$DB_USER" ]; do
    echo "❌ O nome do usuário não pode ser vazio."
    read -p "🧑‍💼 Informe o nome do usuário do banco: " DB_USER
done

while true; do
    read -s -p "🔑 Informe a senha do banco: " DB_PASS
    echo ""

    # Validação: senha não pode ser vazia nem muito curta
    if [ -z "$DB_PASS" ]; then
        echo "❌ A senha não pode ser vazia."
        continue
    fi
    if [ ${#DB_PASS} -lt 8 ]; then
        echo "❌ A senha deve ter pelo menos 8 caracteres."
        continue
    fi

    read -s -p "🔁 Confirme a senha: " DB_PASS_CONFIRM
    echo ""

    if [ "$DB_PASS" == "$DB_PASS_CONFIRM" ]; then
        break
    else
        echo "❌ Senhas não coincidem. Tente novamente."
    fi
done

echo ""
echo "  Usuário do banco : $DB_USER"
echo "  Banco de dados   : zabbix"
echo ""
read -p "❓ Continuar com esses dados? (s/n): " CONFIRM
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    echo "❌ Instalação cancelada pelo usuário."
    exit 1
fi

# ==============================
# Adiciona repositório Zabbix 6.4
# ==============================
echo ""
echo "📥 Instalando repositório Zabbix 6.4..."
ZABBIX_DEB="zabbix-release_6.4-1+ubuntu22.04_all.deb"
wget -q "https://repo.zabbix.com/zabbix/6.4/ubuntu/pool/main/z/zabbix-release/${ZABBIX_DEB}"
dpkg -i "$ZABBIX_DEB"
rm -f "$ZABBIX_DEB"
apt update

# ==============================
# Instala Zabbix Server, Frontend e Agent
# ==============================
echo "📦 Instalando Zabbix Server, Frontend e Agent..."
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-agent apache2

# ==============================
# Instala MariaDB
# ==============================
echo "💾 Instalando MariaDB..."
apt install -y mariadb-server
systemctl enable mariadb
systemctl start mariadb

# ==============================
# Cria banco de dados Zabbix
# ==============================
echo "⚙️  Criando banco de dados Zabbix..."
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON zabbix.* TO '${DB_USER}'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
EOF

# ==============================
# Importa schema do Zabbix
# (senha via arquivo temporário — evita exposição em ps/history)
# ==============================
echo "📤 Importando schema do Zabbix..."

MYSQL_OPT=$(mktemp)
chmod 600 "$MYSQL_OPT"
cat > "$MYSQL_OPT" <<OPTEOF
[client]
password=${DB_PASS}
OPTEOF

SCHEMA_IMPORTED=false

for SCHEMA_PATH in \
    /usr/share/doc/zabbix-server-mysql*/create.sql.gz \
    /usr/share/zabbix-server-mysql*/create.sql.gz; do

    # Expande glob — pula se não encontrar arquivo
    SCHEMA_FILE=$(compgen -G "$SCHEMA_PATH" 2>/dev/null | head -n1) || true

    if [ -n "$SCHEMA_FILE" ] && [ -f "$SCHEMA_FILE" ]; then
        echo "   Usando schema: $SCHEMA_FILE"
        zcat "$SCHEMA_FILE" | \
            mysql --defaults-extra-file="$MYSQL_OPT" \
                  --default-character-set=utf8mb4 \
                  -u"${DB_USER}" zabbix
        SCHEMA_IMPORTED=true
        break
    fi
done

rm -f "$MYSQL_OPT"

if [ "$SCHEMA_IMPORTED" = false ]; then
    echo "❌ Arquivo de schema não encontrado. Verifique a instalação do zabbix-server-mysql."
    exit 1
fi

# Desabilita log_bin_trust_function_creators após importação
mysql -uroot <<EOF
SET GLOBAL log_bin_trust_function_creators = 0;
EOF

# ==============================
# Configura zabbix_server.conf
# (DBPassword e DBUser)
# ==============================
echo "🔧 Configurando zabbix_server.conf..."
ZABBIX_CONF="/etc/zabbix/zabbix_server.conf"

# DBPassword
if grep -q "^#*DBPassword=" "$ZABBIX_CONF"; then
    sed -i "s|^#*DBPassword=.*|DBPassword=${DB_PASS}|" "$ZABBIX_CONF"
else
    echo "DBPassword=${DB_PASS}" >> "$ZABBIX_CONF"
fi

# DBUser
if grep -q "^#*DBUser=" "$ZABBIX_CONF"; then
    sed -i "s|^#*DBUser=.*|DBUser=${DB_USER}|" "$ZABBIX_CONF"
else
    echo "DBUser=${DB_USER}" >> "$ZABBIX_CONF"
fi

# ==============================
# Inicia e habilita serviços Zabbix
# ==============================
echo "🚀 Iniciando serviços Zabbix..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

# ==============================
# Instala Grafana (repositório atual: apt.grafana.com)
# ==============================
echo ""
echo "📊 Instalando Grafana..."
mkdir -p /usr/share/keyrings

wget -q -O - https://apt.grafana.com/gpg.key | \
    gpg --dearmor > /usr/share/keyrings/grafana.gpg

echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list

apt update
apt install -y grafana
systemctl enable grafana-server
systemctl start grafana-server

# ==============================
# Aguarda Grafana ficar pronto (substituí sleep 5 fixo)
# ==============================
echo "⏳ Aguardando Grafana inicializar..."
GRAFANA_TIMEOUT=60
GRAFANA_READY=false

for i in $(seq 1 $GRAFANA_TIMEOUT); do
    if curl -sf http://localhost:3000/api/health > /dev/null 2>&1; then
        GRAFANA_READY=true
        echo "   Grafana pronto após ${i}s."
        break
    fi
    sleep 1
done

if [ "$GRAFANA_READY" = false ]; then
    echo "⚠️  Grafana não respondeu em ${GRAFANA_TIMEOUT}s. Tentando instalar o plugin mesmo assim..."
fi

# ==============================
# Instala plugin Zabbix no Grafana
# ==============================
echo "🔌 Instalando plugin Zabbix no Grafana..."
grafana-cli plugins install alexanderzobnin-zabbix-app
systemctl restart grafana-server

# ==============================
# Finalização
# ==============================
SERVER_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')

echo ""
echo "============================================"
echo "  ✅ Instalação concluída com sucesso!"
echo "============================================"
echo "  🌐 Zabbix  : http://${SERVER_IP}/zabbix"
echo "  📊 Grafana : http://${SERVER_IP}:3000"
echo "               Login padrão: admin / admin"
echo "  📋 Log     : ${LOG_FILE}"
echo "============================================"
echo "  ⚠️  Lembre-se de:"
echo "     1. Finalizar o setup web do Zabbix"
echo "     2. Trocar a senha padrão do Grafana"
echo "     3. Ativar o plugin Zabbix no Grafana"
echo "============================================"
