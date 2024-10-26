#!/bin/bash

# Variáveis
ZABBIX_VERSION="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb"
GRAFANA_VERSION="4.5.6"
TIMEZONE="America/Sao_Paulo"
LOCALE="pt_BR.UTF-8"
DB_NAME="zabbix"
DB_USER="zabbix"
DB_PASSWORD=$(openssl rand -base64 12)  # Senha aleatória para segurança

# Verificar se o script está sendo executado como root
if [[ "$EUID" -ne 0 ]]; then
    echo "Por favor, execute este script como root."
    exit 1
fi

# Configurar timezone e locale
echo "Configuring timezone and locale..."
timedatectl set-timezone "$TIMEZONE"
locale-gen "$LOCALE"
update-locale LANG="$LOCALE"

# Instalar dependências
echo "Updating system and installing prerequisites..."
apt update -y
apt install -y wget gnupg2 software-properties-common || { echo "Erro ao instalar pacotes necessários"; exit 1; }

# Instalar Zabbix
echo "Installing Zabbix repository..."
wget "$ZABBIX_VERSION" -O /tmp/zabbix-release.deb || { echo "Erro ao baixar o pacote Zabbix"; exit 1; }
dpkg -i /tmp/zabbix-release.deb || { echo "Erro ao instalar o pacote Zabbix"; exit 1; }
apt update -y

echo "Installing Zabbix packages..."
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent || { echo "Erro ao instalar Zabbix"; exit 1; }

# Configurar banco de dados para Zabbix
echo "Configuring MySQL database for Zabbix..."
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
EOF

# Importar o esquema inicial do Zabbix usando o usuário root
SQL_FILE="/usr/share/zabbix-sql-scripts/mysql/server.sql.gz"

if [[ -f "$SQL_FILE" ]]; then
    echo "Importing Zabbix schema as root..."
    zcat "$SQL_FILE" | mysql --default-character-set=utf8mb4 -uroot "$DB_NAME" || { echo "Erro ao importar o esquema do Zabbix"; exit 1; }
else
    echo "Arquivo SQL não encontrado em $SQL_FILE. Verifique a instalação do Zabbix."
    exit 1
fi

# Reverter log_bin_trust_function_creators após a importação
mysql -uroot <<EOF
SET GLOBAL log_bin_trust_function_creators = 0;
EOF

# Configurar arquivo zabbix_server.conf
echo "Configuring Zabbix server..."
sed -i "s/^DBPassword=.*/DBPassword=$DB_PASSWORD/" /etc/zabbix/zabbix_server.conf

# Configurar PHP para Zabbix
sed -i "s/^;date.timezone =.*/date.timezone = $TIMEZONE/" /etc/zabbix/apache.conf

# Reiniciar serviços Zabbix e Apache
echo "Starting Zabbix and Apache services..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

# Instalar e configurar Grafana
echo "Installing Grafana..."
wget "https://dl.grafana.com/oss/release/grafana_${GRAFANA_VERSION}_amd64.deb" -O /tmp/grafana.deb || { echo "Erro ao baixar o pacote Grafana"; exit 1; }
dpkg -i /tmp/grafana.deb || { echo "Erro ao instalar Grafana"; exit 1; }
apt install -f -y || { echo "Erro ao instalar dependências do Grafana"; exit 1; }

systemctl daemon-reload
systemctl start grafana-server
systemctl enable grafana-server

# Mensagens de conclusão e credenciais
echo "Installation complete."
echo "Zabbix database name: $DB_NAME"
echo "Zabbix database user: $DB_USER"
echo "Zabbix database password: $DB_PASSWORD"
echo "Grafana version $GRAFANA_VERSION installed and running."
