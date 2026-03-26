#!/bin/bash

# ==============================
#  INSTALAÇÃO ZABBIX 7.0 + APACHE + GRAFANA
#  PARA UBUNTU 22.04 LTS
# ==============================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Execute como root: sudo $0"
    exit 1
fi

# ==============================
# Atualização e dependências
# ==============================
echo "🛠 Atualizando sistema e instalando dependências..."
apt update && apt upgrade -y
apt --fix-broken install -y
dpkg --configure -a
apt autoremove -y
apt autoclean -y

apt install -y snmp snmp-mibs-downloader nano curl wget gnupg2 software-properties-common lsb-release ca-certificates apt-transport-https

sed -i 's/^mibs :/# mibs :/' /etc/snmp/snmp.conf

# ==============================
# Configuração do Banco de Dados
# ==============================
echo ""
echo "=============================="
echo "  CONFIGURAÇÃO DO BANCO DE DADOS"
echo "=============================="

# Usuário do DB
while true; do
    read -p "🧑‍💼 Nome do usuário do banco (ex: zabbix): " DB_USER
    if [[ -n "$DB_USER" && ! "$DB_USER" =~ [[:space:]] ]]; then
        break
    else
        echo "❌ Nome de usuário inválido."
    fi
done

# Senha do DB
while true; do
    read -s -p "🔑 Senha do banco: " DB_PASS
    echo ""
    read -s -p "🔁 Confirme a senha: " DB_PASS_CONFIRM
    echo ""
    if [ "$DB_PASS" == "$DB_PASS_CONFIRM" ]; then
        break
    else
        echo "❌ Senhas não coincidem."
    fi
done

echo ""
read -p "❓ Continuar com esses dados? (s/n): " CONFIRM
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    echo "❌ Instalação cancelada."
    exit 1
fi

# ==============================
# Repositório Zabbix
# ==============================
echo "📥 Instalando repositório Zabbix..."
wget -q https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu22.04_all.deb
dpkg -i zabbix-release_latest_7.0+ubuntu22.04_all.deb
rm -f zabbix-release_latest_7.0+ubuntu22.04_all.deb
apt update

# ==============================
# Instala Zabbix + Apache + Agent2
# ==============================
echo "📦 Instalando Zabbix Server, Frontend, Apache e Agent2..."
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent2 apache2

# ==============================
# MariaDB
# ==============================
echo "💾 Instalando MariaDB..."
apt install -y mariadb-server
systemctl enable mariadb
systemctl start mariadb

# Cria DB Zabbix
echo "⚙️ Criando banco de dados Zabbix..."
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON zabbix.* TO '${DB_USER}'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
EOF

# Importa schema
echo "📤 Importando schema do Zabbix..."
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -u${DB_USER} -p${DB_PASS} zabbix

mysql -uroot <<EOF
SET GLOBAL log_bin_trust_function_creators = 0;
EOF

# Configura senha no Zabbix server
sed -i "s|^#*DBPassword=.*|DBPassword=${DB_PASS}|" /etc/zabbix/zabbix_server.conf || echo "DBPassword=${DB_PASS}" >> /etc/zabbix/zabbix_server.conf

# ==============================
# Inicia e habilita serviços Zabbix
# ==============================
systemctl restart zabbix-server zabbix-agent2 apache2
systemctl enable zabbix-server zabbix-agent2 apache2

# ==============================
# Grafana + Plugin Zabbix
# ==============================
echo "📊 Instalando Grafana..."
mkdir -p /usr/share/keyrings
wget -q -O - https://packages.grafana.com/gpg.key | gpg --dearmor > /usr/share/keyrings/grafana.gpg
echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://packages.grafana.com/oss/deb stable main" > /etc/apt/sources.list.d/grafana.list
apt update
apt install -y grafana
systemctl enable grafana-server
systemctl start grafana-server

sleep 5
echo "🔌 Instalando plugin Zabbix no Grafana..."
grafana-cli plugins install alexanderzobnin-zabbix-app
systemctl restart grafana-server

# ==============================
# Finalização
# ==============================
echo -e "\e[36m"
echo "███████╗ █████╗ ██████╗ ██████╗ ██╗██╗  ██╗"
echo "╚══███╔╝██╔══██╗██╔══██╗██╔══██╗██║╚██╗██╔╝"
echo "  ███╔╝ ███████║██████╔╝██████╔╝██║ ╚███╔╝ "
echo " ███╔╝  ██╔══██║██╔══██╗██╔══██╗██║ ██╔██╗ "
echo "███████╗██║  ██║██████╔╝██████╔╝██║██╔╝ ██╗"
echo "╚══════╝╚═╝  ╚═╝╚═════╝ ╚═════╝ ╚═╝╚═╝  ╚═╝"
echo -e "\e[0m"
SERVER_IP=$(ip route get 1 | awk '{print $7;exit}')
echo ""
echo "✅ Instalação concluída!"
echo "🌐 Zabbix: http://${SERVER_IP}/zabbix"
echo "📊 Grafana: http://${SERVER_IP}:3000 (login: admin / admin)"
echo "⚠️ Ative o plugin Zabbix no Grafana após o login inicial."
