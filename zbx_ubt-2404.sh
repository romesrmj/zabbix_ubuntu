#!/bin/bash

# Configurações de variáveis dinâmicas
read -p "Insira o nome desejado para o banco de dados (padrão: zabbix_db): " DB_NAME
DB_NAME=${DB_NAME:-zabbix_db}

read -p "Insira o nome desejado para o usuário do banco de dados (padrão: zabbix_user): " DB_USER
DB_USER=${DB_USER:-zabbix_user}

ZABBIX_VERSION="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb"
TIMEZONE="America/Sao_Paulo"
LOCALE="pt_BR.UTF-8"
GRAFANA_VERSION="https://dl.grafana.com/enterprise/release/grafana-enterprise_9.5.3_amd64.deb"

# Função para remover instalações anteriores
remove_existing() {
    echo "Removendo Zabbix e Grafana existentes..."
    systemctl stop zabbix-server zabbix-agent apache2 grafana-server
    apt-get purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent grafana
    apt-get autoremove -y
}

# Verificar se o script está sendo executado como root
if [[ "$EUID" -ne 0 ]]; then
    echo "Por favor, execute este script como root."
    exit 1
fi

# Remover instalação anterior do Zabbix e Grafana
remove_existing

# Configurar timezone
echo "Configurando timezone..."
timedatectl set-timezone "$TIMEZONE" || { echo "Erro ao definir o timezone"; exit 1; }

# Configurar locale
echo "Configurando locale..."
locale-gen $LOCALE
update-locale LANG=$LOCALE || { echo "Erro ao configurar o locale"; exit 1; }

# Instalar pacotes necessários
echo "Atualizando sistema e instalando pré-requisitos..."
apt update -y
apt install -y wget gnupg2 software-properties-common mysql-server || { echo "Erro ao instalar pacotes necessários"; exit 1; }

# Solicitar senha do root do MySQL
read -s -p "Insira a senha do root do MySQL: " MYSQL_ROOT_PASSWORD
echo

# Solicitar senha para o usuário do Zabbix
read -s -p "Insira a senha para o usuário do Zabbix: " ZABBIX_USER_PASSWORD
echo

# Criar banco de dados e usuário do Zabbix
echo "Criando banco de dados e usuário do Zabbix..."
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;" || { echo "Erro ao criar o banco de dados"; exit 1; }
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_USER_PASSWORD';" || { echo "Erro ao criar o usuário"; exit 1; }
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" || { echo "Erro ao conceder privilégios"; exit 1; }
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;" || { echo "Erro ao atualizar privilégios"; exit 1; }

# Instalar Zabbix
echo "Instalando Zabbix..."
wget "$ZABBIX_VERSION" -O /tmp/zabbix-release.deb || { echo "Erro ao baixar o pacote Zabbix"; exit 1; }
dpkg -i /tmp/zabbix-release.deb || { echo "Erro ao instalar o pacote Zabbix"; exit 1; }
apt update -y
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent zabbix-sql-scripts || { echo "Erro ao instalar Zabbix"; exit 1; }

# Importar o esquema inicial para o banco de dados Zabbix
echo "Importando esquema inicial para o banco de dados Zabbix..."
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_NAME" || { echo "Erro ao importar o esquema do banco de dados Zabbix"; exit 1; }

# Instalar Grafana
echo "Instalando Grafana..."
wget "$GRAFANA_VERSION" -O /tmp/grafana.deb || { echo "Erro ao baixar o pacote Grafana"; exit 1; }
dpkg -i /tmp/grafana.deb || { echo "Erro ao instalar o pacote Grafana"; exit 1; }
apt-get install -f -y || { echo "Erro ao corrigir dependências do Grafana"; exit 1; }

# Instalar plugin do Zabbix no Grafana
grafana-cli plugins install alexanderzobnin-zabbix-app || { echo "Erro ao instalar o plugin Zabbix para Grafana"; exit 1; }
systemctl restart grafana-server

# Redefinir senha do usuário do Zabbix após instalação
echo "Redefinindo senha do usuário Zabbix..."
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_USER_PASSWORD'; FLUSH PRIVILEGES;" || { echo "Erro ao redefinir senha do usuário Zabbix"; exit 1; }

# Mensagem final com informações de acesso
clear
echo "$########################################################################$"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "$########################################################################$"
echo "Instalação do Zabbix e Grafana concluída com sucesso."
echo "Acesse o Zabbix na URL: http://$SERVER_IP/zabbix"
echo "Acesse o Grafana na URL: http://$SERVER_IP:3000"
echo "A senha do usuário Zabbix para o banco de dados é: $ZABBIX_USER_PASSWORD"
echo "$########################################################################$"
