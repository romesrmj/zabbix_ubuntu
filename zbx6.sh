#!/bin/bash

# ============================================================
# INSTALAÇÃO DEFINITIVA — ZABBIX 6.4 + APACHE + GRAFANA
# Ubuntu 22.04 LTS
# Locale: pt_BR / Fuso horário: America/Sao_Paulo
# Versão: 2.0 — testada e validada em produção
# ============================================================

set -euo pipefail

# ============================================================
# Log completo
# ============================================================
LOG_FILE="/var/log/zabbix-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo "  Início da instalação: $(date)"
echo "============================================================"

# ============================================================
# Verificação de root
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Execute como root: sudo $0"
    exit 1
fi

# ============================================================
# Verificação de versão do Ubuntu
# ============================================================
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

echo "✅ Ubuntu 22.04 detectado. Prosseguindo..."

# ============================================================
# Configuração de locale e fuso horário — São Paulo
# ============================================================
echo ""
echo "🌎 Configurando locale e fuso horário para São Paulo..."

# Timezone
timedatectl set-timezone America/Sao_Paulo

# Locale pt_BR.UTF-8
apt-get install -y locales > /dev/null 2>&1
locale-gen pt_BR.UTF-8
update-locale \
    LANG=pt_BR.UTF-8 \
    LC_ALL=pt_BR.UTF-8 \
    LC_MESSAGES=pt_BR.UTF-8 \
    LC_TIME=pt_BR.UTF-8 \
    LC_NUMERIC=pt_BR.UTF-8 \
    LC_MONETARY=pt_BR.UTF-8

# Aplicar imediatamente para o script atual
export LANG=pt_BR.UTF-8
export LC_ALL=pt_BR.UTF-8

# Sincronizar relógio via NTP
timedatectl set-ntp true

echo "   Timezone : $(timedatectl | grep 'Time zone' | awk '{print $3}')"
echo "   Data/Hora: $(date '+%d/%m/%Y %H:%M:%S')"
echo "   Locale   : $(locale | grep LANG= | head -1)"

# ============================================================
# Configuração do banco de dados (interativo)
# ============================================================
echo ""
echo "============================================================"
echo "  CONFIGURAÇÃO DO BANCO DE DADOS"
echo "============================================================"

read -p "🧑 Informe o nome do usuário do banco (ex: zabbix): " DB_USER

while [ -z "$DB_USER" ]; do
    echo "❌ O nome do usuário não pode ser vazio."
    read -p "🧑 Informe o nome do usuário do banco: " DB_USER
done

while true; do
    read -s -p "🔑 Informe a senha do banco: " DB_PASS
    echo ""
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
    if [ "$DB_PASS" = "$DB_PASS_CONFIRM" ]; then
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

# ============================================================
# Atualizar sistema e instalar dependências
# ============================================================
echo ""
echo "🛠  Atualizando sistema..."
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get upgrade -y -qq
apt-get --fix-broken install -y -qq
dpkg --configure -a
apt-get autoremove -y -qq
apt-get autoclean -y -qq

apt-get install -y \
    snmp \
    snmp-mibs-downloader \
    nano \
    curl \
    wget \
    gnupg2 \
    software-properties-common \
    lsb-release \
    ca-certificates \
    apt-transport-https \
    locales \
    tzdata

# Corrige SNMP para exibir MIBs
if grep -q "^mibs :" /etc/snmp/snmp.conf 2>/dev/null; then
    sed -i 's/^mibs :/# mibs :/' /etc/snmp/snmp.conf
fi

# ============================================================
# Instala MariaDB
# ============================================================
echo ""
echo "💾 Instalando MariaDB..."
apt-get install -y mariadb-server
systemctl enable mariadb
systemctl start mariadb

# Aguarda MariaDB estar pronto
echo "   Aguardando MariaDB inicializar..."
for i in $(seq 1 30); do
    if mysqladmin ping -uroot --silent 2>/dev/null; then
        echo "   MariaDB pronto após ${i}s."
        break
    fi
    sleep 1
done

# ============================================================
# Cria banco de dados Zabbix
# ============================================================
echo "⚙️  Criando banco de dados e usuário Zabbix..."
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON zabbix.* TO '${DB_USER}'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
EOF

# ============================================================
# Adiciona repositório Zabbix 6.4
# ============================================================
echo ""
echo "📥 Adicionando repositório Zabbix 6.4..."
ZABBIX_DEB="zabbix-release_6.4-1+ubuntu22.04_all.deb"
wget -q "https://repo.zabbix.com/zabbix/6.4/ubuntu/pool/main/z/zabbix-release/${ZABBIX_DEB}" \
    -O "/tmp/${ZABBIX_DEB}"
dpkg -i "/tmp/${ZABBIX_DEB}"
rm -f "/tmp/${ZABBIX_DEB}"
apt-get update -qq

# ============================================================
# Instala Zabbix Server, Frontend, Agent e SQL Scripts
# ============================================================
echo "📦 Instalando Zabbix Server, Frontend, Agent e SQL Scripts..."
apt-get install -y \
    zabbix-server-mysql \
    zabbix-frontend-php \
    zabbix-apache-conf \
    zabbix-sql-scripts \
    zabbix-agent \
    apache2

# ============================================================
# Importa schema do Zabbix
# (senha via arquivo temporário — sem exposição em ps/history)
# ============================================================
echo "📤 Importando schema do Zabbix..."

SCHEMA_FILE="/usr/share/zabbix-sql-scripts/mysql/server.sql.gz"

if [ ! -f "$SCHEMA_FILE" ]; then
    # Fallback: localiza qualquer schema disponível
    SCHEMA_FILE=$(find /usr/share -name "server.sql.gz" -o -name "create.sql.gz" 2>/dev/null | head -n1)
fi

if [ -z "$SCHEMA_FILE" ] || [ ! -f "$SCHEMA_FILE" ]; then
    echo "❌ Arquivo de schema não encontrado. Abortando."
    exit 1
fi

echo "   Schema encontrado: $SCHEMA_FILE"

MYSQL_OPT=$(mktemp)
chmod 600 "$MYSQL_OPT"
cat > "$MYSQL_OPT" <<OPTEOF
[client]
password=${DB_PASS}
OPTEOF

zcat "$SCHEMA_FILE" | \
    mysql --defaults-extra-file="$MYSQL_OPT" \
          --default-character-set=utf8mb4 \
          -u"${DB_USER}" zabbix

rm -f "$MYSQL_OPT"

# Desabilita log_bin_trust_function_creators após importação
mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;"

echo "   Schema importado com sucesso."

# ============================================================
# Configura zabbix_server.conf
# ============================================================
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

# ============================================================
# Configura PHP para o timezone de São Paulo
# ============================================================
echo "🕐 Configurando PHP timezone..."
PHP_CONF=$(find /etc/zabbix -name "*.conf" | grep -i apache 2>/dev/null | head -n1)

if [ -n "$PHP_CONF" ]; then
    sed -i "s|.*php_value date.timezone.*|        php_value date.timezone America/Sao_Paulo|" "$PHP_CONF"
fi

# Também aplica no php.ini global
PHP_INI=$(php --ini 2>/dev/null | grep "Loaded Configuration" | awk '{print $NF}')
if [ -n "$PHP_INI" ] && [ -f "$PHP_INI" ]; then
    sed -i "s|^;*date.timezone.*|date.timezone = America/Sao_Paulo|" "$PHP_INI"
fi

# ============================================================
# Inicia e habilita serviços Zabbix
# ============================================================
echo ""
echo "🚀 Iniciando serviços Zabbix..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

# Verifica se o Zabbix Server subiu corretamente
sleep 3
if ! systemctl is-active --quiet zabbix-server; then
    echo "❌ zabbix-server não iniciou. Verifique: journalctl -u zabbix-server -n 50"
    exit 1
fi
echo "   zabbix-server: $(systemctl is-active zabbix-server)"
echo "   zabbix-agent : $(systemctl is-active zabbix-agent)"
echo "   apache2      : $(systemctl is-active apache2)"

# ============================================================
# Instala Grafana (repositório oficial atual: apt.grafana.com)
# ============================================================
echo ""
echo "📊 Instalando Grafana..."
mkdir -p /usr/share/keyrings

wget -q -O - https://apt.grafana.com/gpg.key | \
    gpg --dearmor > /usr/share/keyrings/grafana.gpg

echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list

apt-get update -qq
apt-get install -y grafana
systemctl enable grafana-server
systemctl start grafana-server

# ============================================================
# Aguarda Grafana ficar pronto (healthcheck real)
# ============================================================
echo "⏳ Aguardando Grafana inicializar..."
GRAFANA_READY=false
for i in $(seq 1 60); do
    if curl -sf http://localhost:3000/api/health > /dev/null 2>&1; then
        GRAFANA_READY=true
        echo "   Grafana pronto após ${i}s."
        break
    fi
    sleep 1
done

if [ "$GRAFANA_READY" = false ]; then
    echo "⚠️  Grafana não respondeu em 60s. Continuando mesmo assim..."
fi

# ============================================================
# Instala plugin Zabbix no Grafana
# ============================================================
echo "🔌 Instalando plugin Zabbix no Grafana..."
grafana-cli plugins install alexanderzobnin-zabbix-app
systemctl restart grafana-server

# Aguarda restart
sleep 5

# ============================================================
# Ativa o plugin via API do Grafana
# ============================================================
echo "🔧 Ativando plugin Zabbix via API do Grafana..."

# Aguarda Grafana voltar após restart
for i in $(seq 1 30); do
    if curl -sf http://localhost:3000/api/health > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

GRAFANA_PLUGIN_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://admin:admin@localhost:3000/api/plugins/alexanderzobnin-zabbix-app/settings \
    -H "Content-Type: application/json" \
    -d '{"enabled":true,"pinned":true,"jsonData":{}}')

if [ "$GRAFANA_PLUGIN_STATUS" = "200" ]; then
    echo "   Plugin Zabbix ativado com sucesso via API."
else
    echo "   ⚠️  Não foi possível ativar o plugin via API (HTTP $GRAFANA_PLUGIN_STATUS)."
    echo "      Ative manualmente em: Configuration → Plugins → Zabbix → Enable"
fi

# ============================================================
# Adiciona datasource Zabbix no Grafana via API
# ============================================================
echo "🔗 Configurando datasource Zabbix no Grafana..."

SERVER_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')

DATASOURCE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://admin:admin@localhost:3000/api/datasources \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"Zabbix\",
        \"type\": \"alexanderzobnin-zabbix-datasource\",
        \"url\": \"http://localhost/zabbix/api_jsonrpc.php\",
        \"access\": \"proxy\",
        \"isDefault\": true,
        \"jsonData\": {
            \"username\": \"Admin\",
            \"trends\": true,
            \"trendsFrom\": \"7d\",
            \"trendsRange\": \"4d\",
            \"cacheTTL\": \"1h\"
        },
        \"secureJsonData\": {
            \"password\": \"zabbix\"
        }
    }")

if [ "$DATASOURCE_STATUS" = "200" ] || [ "$DATASOURCE_STATUS" = "409" ]; then
    echo "   Datasource Zabbix configurado no Grafana."
else
    echo "   ⚠️  Datasource não configurado automaticamente (HTTP $DATASOURCE_STATUS)."
    echo "      Configure manualmente em: Configuration → Data Sources → Add"
fi

# ============================================================
# Resumo final
# ============================================================
echo ""
echo "============================================================"
echo "  ✅ INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo "  $(date '+%d/%m/%Y %H:%M:%S') — $(timedatectl | grep 'Time zone' | awk '{print $3}')"
echo "============================================================"
echo ""
echo "  🌐 Zabbix Frontend"
echo "     URL    : http://${SERVER_IP}/zabbix"
echo "     Login  : Admin"
echo "     Senha  : zabbix"
echo ""
echo "  📊 Grafana"
echo "     URL    : http://${SERVER_IP}:3000"
echo "     Login  : admin"
echo "     Senha  : admin  ← troque no primeiro acesso!"
echo ""
echo "  🗄️  Banco de dados"
echo "     Banco  : zabbix"
echo "     Usuário: ${DB_USER}"
echo ""
echo "  📋 Log completo: ${LOG_FILE}"
echo ""
echo "============================================================"
echo "  📋 CHECKLIST PÓS-INSTALAÇÃO"
echo "============================================================"
echo "  [ ] Finalizar wizard web do Zabbix (http://${SERVER_IP}/zabbix)"
echo "  [ ] Trocar senha padrão do Zabbix (Admin/zabbix)"
echo "  [ ] Trocar senha padrão do Grafana (admin/admin)"
echo "  [ ] Verificar datasource Zabbix no Grafana"
echo "  [ ] Confirmar plugin Zabbix ativo no Grafana"
echo "  [ ] Configurar firewall (portas 80, 3000, 10051)"
echo "============================================================"
