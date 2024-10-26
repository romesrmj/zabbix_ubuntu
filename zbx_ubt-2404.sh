#!/bin/bash

# Variáveis
ZABBIX_VERSION="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb"
GRAFANA_VERSION="4.5.6"
TIMEZONE="America/Sao_Paulo"
LOCALE="pt_BR.UTF-8"

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

# Configuração do MySQL
echo "Configuring MySQL..."
mysql -uroot -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;" || { echo "Erro ao criar banco de dados"; exit 1; }
mysql -uroot -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';" || { echo "Erro ao criar usuário do banco de dados"; exit 1; }
mysql -uroot -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
mysql -uroot -e "FLUSH PRIVILEGES;" || { echo "Erro ao configurar privilégios do banco de dados"; exit 1; }

# Configurar Zabbix para o MySQL
ZABBIX_SQL_FILE=$(find /usr/share/doc -name "create.sql.gz" | grep "zabbix-server-mysql")
if [ -f "$ZABBIX_SQL_FILE" ]; then
    echo "Importing initial schema to Zabbix database..."
    zcat "$ZABBIX_SQL_FILE" | mysql -u$DB_USER -p$DB_PASSWORD $DB_NAME || { echo "Erro ao importar o esquema do banco de dados Zabbix"; exit 1; }
else
    echo "Arquivo SQL para Zabbix não encontrado"
    exit 1
fi

# Atualizar configuração do Zabbix
sed -i "s/^DBPassword=.*/DBPassword=$DB_PASSWORD/" /etc/zabbix/zabbix_server.conf

# Configurar PHP para Zabbix
sed -i "s/^;date.timezone =.*/date.timezone = $TIMEZONE/" /etc/zabbix/apache.conf

# Reiniciar serviços do Zabbix e verificar status
echo "Restarting Zabbix services..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

if systemctl is-active --quiet zabbix-server && systemctl is-active --quiet apache2; then
    echo "Zabbix server e Apache foram iniciados com sucesso."
else
    echo "Erro ao iniciar os serviços Zabbix ou Apache."
    exit 1
fi

# Instalar Grafana
echo "Installing Grafana..."
wget "https://dl.grafana.com/oss/release/grafana_${GRAFANA_VERSION}_amd64.deb" -O /tmp/grafana.deb || { echo "Erro ao baixar o pacote Grafana"; exit 1; }
dpkg -i /tmp/grafana.deb
apt install -f -y || { echo "Erro ao instalar Grafana"; exit 1; }

# Configurar Grafana para iniciar com o sistema
echo "Starting Grafana..."
systemctl daemon-reload
systemctl start grafana-server
systemctl enable grafana-server

if systemctl is-active --quiet grafana-server; then
    echo "Grafana foi iniciado com sucesso."
else
    echo "Erro ao iniciar o Grafana."
    exit 1
fi

# Finalização
echo "Installation complete."
echo "Zabbix database name: $DB_NAME"
echo "Zabbix database user: $DB_USER"
echo "Zabbix database password: $DB_PASSWORD"
echo "Grafana version $GRAFANA_VERSION installed and running."
echo "Zabbix and Grafana should be accessible shortly."
