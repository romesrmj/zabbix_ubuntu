#!/bin/bash

# Variáveis
ZABBIX_VERSION="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb"
TIMEZONE="America/Sao_Paulo"
LOCALE="pt_BR.UTF-8"
DB_NAME="zabbix_db"
DB_USER="zabbix_user"
DB_PASSWORD="your_secure_password"  # Mude para uma senha forte

# Função para verificar a instalação de pacotes
check_install() {
    if ! dpkg -l | grep -q "$1"; then
        echo "$1 não está instalado. Instalando..."
        apt-get install -y "$1" || { echo "Erro ao instalar $1"; exit 1; }
    else
        echo "$1 já está instalado."
    fi
}

# Função para verificar se o banco de dados e o usuário existem
check_db_user() {
    local db_exists=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES LIKE '$DB_NAME';" | grep "$DB_NAME" | wc -l)
    local user_exists=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT User FROM mysql.user WHERE User = '$DB_USER';" | grep "$DB_USER" | wc -l)

    echo "Verificando banco de dados e usuário..."
    if [ "$db_exists" -eq 1 ]; then
        echo "O banco de dados '$DB_NAME' já existe."
    else
        echo "O banco de dados '$DB_NAME' não existe."
    fi

    if [ "$user_exists" -eq 1 ]; then
        echo "O usuário '$DB_USER' já existe."
    else
        echo "O usuário '$DB_USER' não existe."
    fi
}

# Função para remover banco de dados e usuário
remove_db_user() {
    echo "Removendo banco de dados e usuário, se existirem..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS $DB_NAME;"
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
}

# Função para configurar o MySQL
setup_mysql() {
    # Instalando MySQL Server
    check_install mysql-server

    # Inicializando o banco de dados
    service mysql start

    # Verificar se o banco de dados e usuário existem
    check_db_user

    # Remover banco de dados e usuário existentes, se existirem
    remove_db_user

    # Criando o banco de dados e usuário
    echo "Criando banco de dados e usuário para Zabbix..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;"
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"
}

# Verifica se o script está sendo executado como root
if [[ "$EUID" -ne 0 ]]; then
    echo "Por favor, execute este script como root."
    exit 1
fi

# Solicitar a senha do root do MySQL
read -s -p "Digite a senha do root do MySQL: " MYSQL_ROOT_PASSWORD
echo

# Remover entidades do Zabbix se já instaladas
remove_zabbix

# Configurar timezone
echo "Configurando timezone..."
timedatectl set-timezone "$TIMEZONE" || { echo "Erro ao definir o timezone"; exit 1; }

# Configurar locale
echo "Configurando locale..."
locale-gen $LOCALE
update-locale LANG=$LOCALE || { echo "Erro ao configurar o locale"; exit 1; }

# Instalar pacotes necessários
echo "Atualizando sistema e instalando dependências..."
apt-get update -y
check_install wget
check_install gnupg2
check_install software-properties-common

# Instalar Zabbix
echo "Instalando Zabbix..."
wget "$ZABBIX_VERSION" -O /tmp/zabbix-release.deb || { echo "Erro ao baixar o pacote Zabbix"; exit 1; }
dpkg -i /tmp/zabbix-release.deb || { echo "Erro ao instalar o pacote Zabbix"; exit 1; }
apt-get update -y

# Instala Zabbix Server e Frontend
check_install zabbix-server-mysql
check_install zabbix-frontend-php
check_install zabbix-apache-conf
check_install zabbix-agent

# Configuração do banco de dados para Zabbix
echo "Configurando banco de dados para Zabbix..."
setup_mysql

# Importar esquema inicial para o banco de dados Zabbix
echo "Importando esquema inicial para o banco de dados Zabbix..."
ZABBIX_SQL_FILE="/usr/share/zabbix-sql-scripts/mysql/server.sql.gz"
if [ -f "$ZABBIX_SQL_FILE" ]; then
    zcat "$ZABBIX_SQL_FILE" | mysql -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" || { echo "Erro ao importar o esquema do banco de dados Zabbix"; exit 1; }
else
    echo "Arquivo SQL para Zabbix não encontrado. Certifique-se de que o Zabbix foi instalado corretamente."
    exit 1
fi

# Atualizar configuração do Zabbix
echo "Atualizando configuração do Zabbix..."
sed -i "s/^DBPassword=.*/DBPassword=$DB_PASSWORD/" /etc/zabbix/zabbix_server.conf
sed -i "s/^;date.timezone =.*/date.timezone = $TIMEZONE/" /etc/zabbix/apache.conf

# Reiniciar serviços do Zabbix
echo "Reiniciando serviços do Zabbix..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

# Verificar status do Zabbix
if systemctl is-active --quiet zabbix-server && systemctl is-active --quiet apache2; then
    echo "Zabbix server e Apache foram iniciados com sucesso."
else
    echo "Erro ao iniciar os serviços Zabbix ou Apache."
    exit 1
fi

# Finalização
echo "Instalação completa."
echo "Zabbix database name: $DB_NAME"
echo "Zabbix database user: $DB_USER"
echo "Zabbix database password: $DB_PASSWORD"
