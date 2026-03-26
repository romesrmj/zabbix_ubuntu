#!/bin/bash

# ==============================
#  INSTALAÇÃO ZABBIX 7.0 + APACHE + GRAFANA
#  PARA UBUNTU 24.04 LTS
#  (Versão com correção de pacotes quebrados)
# ==============================

if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Execute como root: sudo ./install_zabbix_apache_ubuntu_24_04.sh"
    exit 1
fi

# ==============================
# Limpar pacotes quebrados e atualizar
# ==============================
echo "🛠 Corrigindo pacotes quebrados e atualizando sistema..."
apt --fix-broken install -y
dpkg --configure -a
apt autoremove -y
apt autoclean -y
apt update && apt upgrade -y

# ==============================
# Instala dependências básicas
# ==============================
echo "📦 Instalando dependências..."
apt install -y snmp snmp-mibs-downloader nano curl wget gnupg2 software-properties-common lsb-release ca-certificates apt-transport-https

# Corrige SNMP para exibir MIBs
sed -i 's/^mibs :/# mibs :/' /etc/snmp/snmp.conf

# ==============================
# INTERATIVIDADE: DB
# ==============================
echo ""
echo "=============================="
echo "  CONFIGURAÇÃO DO BANCO DE DADOS"
echo "=============================="

read -p "🧑‍💼 Informe o nome do usuário do banco (ex: zabbix): " DB_USER
read -s -p "🔑 Informe a senha do banco: " DB_PASS
echo ""
read -s -p "🔁 Confirme a senha do banco: " DB_PASS_CONFIRM
echo ""

if [ "$DB_PASS" != "$DB_PASS_CONFIRM" ]; then
    echo "❌ As senhas não coincidem. Abortando."
    exit 1
fi

echo ""
echo "📋 Usuário do banco: $DB_USER"
echo "🔒 Senha: [oculta]"
read -p "❓ Continuar com esses dados? (s/n): " CONFIRM
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    echo "❌ Instalação cancelada."
    exit 1
fi

# ==============================
# Repositório Zabbix
# ==============================
echo "📥 Instalando repositório Zabbix..."
wget -q https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb
dpkg -i zabbix-release_latest_7.0+ubuntu24.04_all.deb || apt --fix-broken install -y
apt update

# ==============================
# Instala Zabbix + Apache
# ==============================
echo "📦 Instalando Zabbix Server + Frontend + Apache..."
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent apache2 || apt --fix-broken install -y

# ==============================
# MariaDB
# ==============================
echo "💾 Instalando MariaDB..."
apt install -y mariadb-server || apt --fix-broken install -y
systemctl enable mariadb
systemctl start mariadb

# Cria DB
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

# Configura senha no zabbix_server.conf
echo "✍️ Configurando /etc/zabbix/zabbix_server.conf..."
sed -i "s|^# DBPassword=|DBPassword=${DB_PASS}|" /etc/zabbix/zabbix_server.conf

# ==============================
# Inicia e habilita serviços
# ==============================
echo "🚀 Iniciando e habilitando serviços..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

# ==============================
# Grafana + Plugin Zabbix
# ==============================
echo "📊 Instalando Grafana..."
wget -q -O - https://packages.grafana.com/gpg.key | gpg --dearmor -o /usr/share/keyrings/grafana.gpg
echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://packages.grafana.com/oss/deb stable main" > /etc/apt/sources.list.d/grafana.list
apt update
apt install -y grafana || apt --fix-broken install -y
systemctl enable grafana-server
systemctl start grafana-server

echo "🔌 Instalando plugin do Zabbix no Grafana..."
grafana-cli plugins install alexanderzobnin-zabbix-app
systemctl restart grafana-server

# ==============================
# Final - mostrando IP real do servidor
# ==============================

# Captura o IP principal da interface ativa
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "✅ Instalação concluída com sucesso!"
echo "🌐 Acesse a interface Zabbix: http://${SERVER_IP}/zabbix"
echo "📊 Acesse o Grafana: http://${SERVER_IP}:3000 (login: admin / admin)"
echo "⚠️ Ative o plugin Zabbix no Grafana após o login inicial."
