#!/bin/bash

# Variáveis
ZABBIX_VERSION="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb"
TIMEZONE="America/Sao_Paulo"
LOCALE="pt_BR.UTF-8"

# Verificar se o script está sendo executado como root
if [[ "$EUID" -ne 0 ]]; then
    echo "Por favor, execute este script como root."
    exit 1
fi

# Solicitar a senha do root do MySQL
read -s -p "Insira uma senha para o root do MySQL: " MYSQL_ROOT_PASSWORD
echo

# Solicitar a senha do banco de dados Zabbix
read -s -p "Insira uma senha para o banco de dados Zabbix: " ZABBIX_PASSWORD
echo

# Configurar timezone
echo "Configurando timezone..."
timedatectl set-timezone "$TIMEZONE" || { echo "Erro ao definir o timezone"; exit 1; }

# Configurar locale
echo "Configurando locale..."
locale-gen $LOCALE
update-locale LANG=$LOCALE || { echo "Erro ao configurar o locale"; exit 1; }

# Instalar pacotes necessários
echo "Atualizando o sistema e instalando pacotes necessários..."
apt update -y
apt install -y wget gnupg2 software-properties-common mysql-server || { echo "Erro ao instalar pacotes necessários"; exit 1; }

# Verificar se o banco de dados Zabbix já existe e removê-lo se necessário
DB_NAME="zabbix_db"
DB_USER="zabbix_user"

# Conectar ao MySQL como root e verificar se o banco de dados e o usuário já existem
DB_CHECK=$(mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES LIKE '$DB_NAME';")
USER_CHECK=$(mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT User FROM mysql.user WHERE User='$DB_USER';")

if [[ "$DB_CHECK" ]]; then
    echo "O banco de dados '$DB_NAME' já existe. Removendo..."
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE $DB_NAME;"
fi

if [[ "$USER_CHECK" ]]; then
    echo "O usuário '$DB_USER' já existe. Removendo..."
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "DROP USER '$DB_USER'@'localhost';"
fi

# Instalar Zabbix
echo "Instalando Zabbix..."
wget "$ZABBIX_VERSION" -O /tmp/zabbix-release.deb || { echo "Erro ao baixar o pacote Zabbix"; exit 1; }
dpkg -i /tmp/zabbix-release.deb || { echo "Erro ao instalar o pacote Zabbix"; exit 1; }
apt update -y
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent || { echo "Erro ao instalar Zabbix"; exit 1; }

# Configurar banco de dados para Zabbix
echo "Configurando banco de dados para Zabbix..."
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;" || { echo "Erro ao criar banco de dados"; exit 1; }
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_PASSWORD';" || { echo "Erro ao criar usuário do banco de dados"; exit 1; }
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;" || { echo "Erro ao configurar privilégios do banco de dados"; exit 1; }

# Importar esquema inicial para o banco de dados Zabbix
echo "Importando esquema inicial para o banco de dados Zabbix..."
ZABBIX_SQL_FILE=$(find /usr/share/doc -name "create.sql.gz" | grep "zabbix-server-mysql")
if [ -f "$ZABBIX_SQL_FILE" ]; then
    zcat "$ZABBIX_SQL_FILE" | mysql -u"$DB_USER" -p"$ZABBIX_PASSWORD" "$DB_NAME" || { echo "Erro ao importar o esquema do banco de dados Zabbix"; exit 1; }
else
    echo "Arquivo SQL para Zabbix não encontrado. Certifique-se de que o Zabbix foi instalado corretamente."
    exit 1
fi

# Atualizar configuração do Zabbix
sed -i "s/^DBPassword=.*/DBPassword=$ZABBIX_PASSWORD/" /etc/zabbix/zabbix_server.conf

# Configurar PHP para Zabbix
sed -i "s/^;date.timezone =.*/date.timezone = $TIMEZONE/" /etc/zabbix/apache.conf

# Reiniciar serviços do Zabbix e verificar status
echo "Reiniciando serviços do Zabbix..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

if systemctl is-active --quiet zabbix-server && systemctl is-active --quiet apache2; then
    echo "Zabbix server e Apache foram iniciados com sucesso."
else
    echo "Erro ao iniciar os serviços Zabbix ou Apache."
    exit 1
fi

# Finalização
echo "Instalação completa."
echo "Banco de dados Zabbix: $DB_NAME"
echo "Usuário do banco de dados: $DB_USER"
echo "Senha do banco de dados: $ZABBIX_PASSWORD"
echo "Zabbix deve estar acessível em breve."
