#!/bin/bash

# Variáveis
ZABBIX_VERSION="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb"
GRAFANA_VERSION="4.5.6"
TIMEZONE="America/Sao_Paulo"
LOCALE="pt_BR.UTF-8"
ZABBIX_SQL_FILE="/tmp/create.sql.gz"

# Função para criar senha aleatória
generate_password() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 12
}

# Senha aleatória para Zabbix
ZABBIX_PASSWORD=$(generate_password)

# Verificar se o script está sendo executado como root
if [[ "$EUID" -ne 0 ]]; then
    echo "Por favor, execute este script como root."
    exit 1
fi

# Configurar timezone
echo "Configuring timezone..."
timedatectl set-timezone "$TIMEZONE" || { echo "Erro ao definir o timezone"; exit 1; }

# Configurar locale
echo "Configuring locale..."
locale-gen $LOCALE
update-locale LANG=$LOCALE || { echo "Erro ao configurar o locale"; exit 1; }

# Instalar pacotes necessários
echo "Updating system and installing prerequisites..."
apt update -y
apt install -y wget gnupg2 software-properties-common || { echo "Erro ao instalar pacotes necessários"; exit 1; }

# Instalar Zabbix
echo "Installing Zabbix..."
wget "$ZABBIX_VERSION" -O /tmp/zabbix-release.deb || { echo "Erro ao baixar o pacote Zabbix"; exit 1; }
dpkg -i /tmp/zabbix-release.deb || { echo "Erro ao instalar o pacote Zabbix"; exit 1; }
apt update -y
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent || { echo "Erro ao instalar Zabbix"; exit 1; }

# Configurar banco de dados para Zabbix
echo "Configuring Zabbix database..."
DB_NAME="zabbix_db"
DB_USER="zabbix_user"
DB_PASSWORD=$(generate_password)
MYSQL_ROOT_PASSWORD=$(generate_password)

# Instalar MySQL Server e configurar
echo "Installing MySQL Server..."
apt install -y mysql-server || { echo "Erro ao instalar MySQL Server"; exit 1; }

# Configuração do MySQL com verificação de existência do banco e usuário
echo "Configuring MySQL..."
mysql -uroot -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;" || { echo "Erro ao criar banco de dados"; exit 1; }
mysql -uroot -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';" || { echo "Erro ao criar usuário do banco de dados"; exit 1; }
mysql -uroot -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
mysql -uroot -e "FLUSH PRIVILEGES;" || { echo "Erro ao configurar privilégios do banco de dados"; exit 1; }

# Tentar baixar o arquivo SQL diretamente do CDN do Zabbix
if ! wget "$ZABBIX_SQL_FILE" -O "$ZABBIX_SQL_FILE"; then
    echo "Erro ao baixar o arqui
