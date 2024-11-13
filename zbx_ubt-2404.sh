#!/bin/bash

set -e  # Parar o script na primeira ocorrência de erro

# Função para remover Zabbix e Grafana, se existentes
remove_existing() {
    echo "Removendo Zabbix e Grafana existentes..."
    systemctl stop zabbix-server zabbix-agent apache2 grafana-server || true
    apt-get purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent grafana nano || true
    apt-get autoremove -y || true
}

clear

# Solicitar o nome do banco de dados e do usuário
read -p "Digite o nome do banco de dados a ser criado (padrão: zabbix_db): " DB_NAME
DB_NAME=${DB_NAME:-zabbix_db}
read -p "Digite o nome do usuário do banco de dados (padrão: zabbix_user): " DB_USER
DB_USER=${DB_USER:-zabbix_user}

# Solicitar senhas
read -s -p "Insira a senha do root do MySQL: " MYSQL_ROOT_PASSWORD
echo
read -s -p "Insira a senha para o usuário do Zabbix: " ZABBIX_USER_PASSWORD
echo

# Verificação de permissão de root
if [[ "$EUID" -ne 0 ]]; then
    echo "Por favor, execute este script como root."
    exit 1
fi

# Remover instalação anterior
remove_existing

# Configurar timezone e locale
echo "Configurando timezone e locale..."
timedatectl set-timezone "America/Sao_Paulo"
locale-gen "pt_BR.UTF-8"
update-locale LANG="pt_BR.UTF-8"

# Instalar pacotes necessários
echo "Atualizando sistema e instalando pré-requisitos..."
apt update -y &>/dev/null
apt install -y wget gnupg2 software-properties-common mysql-server nano &>/dev/null

# Verificar e excluir banco e usuário existentes, se necessário
echo "Verificando se o banco e o usuário já existem..."
DB_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES LIKE '$DB_NAME';" 2>/dev/null || true)
if [[ -n "$DB_EXIST" ]]; then
    echo "O banco de dados '$DB_NAME' já existe. Removendo..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE $DB_NAME;" || { echo "Erro ao remover o banco de dados"; exit 1; }
fi

USER_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '$DB_USER');" 2>/dev/null || true)
if [[ "$USER_EXIST" == *"1"* ]]; then
    echo "O usuário '$DB_USER' já existe. Removendo..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" || { echo "Erro ao remover o usuário"; exit 1; }
fi

# Criar banco de dados e usuário
echo "Criando banco de dados e usuário do Zabbix..."
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;" || { echo "Erro ao criar o banco de dados"; exit 1; }
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_USER_PASSWORD';" || { echo "Erro ao criar o usuário"; exit 1; }
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;" || { echo "Erro ao conceder permissões ao usuário"; exit 1; }

# Instalar Zabbix
echo "Instalando Zabbix..."
wget "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb" -O /tmp/zabbix-release.deb &>/dev/null
dpkg -i /tmp/zabbix-release.deb || { echo "Erro ao instalar o pacote do Zabbix"; exit 1; }
apt update -y &>/dev/null
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent zabbix-sql-scripts &>/dev/null || { echo "Erro ao instalar os pacotes do Zabbix"; exit 1; }

# Importar esquema inicial
echo "Importando esquema inicial para o banco de dados Zabbix..."
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_NAME" || { echo "Erro ao importar esquema inicial"; exit 1; }

# Atualizar configuração do Zabbix
echo "Atualizando configuração do Zabbix..."
if [ -f /etc/zabbix/zabbix_server.conf ]; then
    cp /etc/zabbix/zabbix_server.conf /etc/zabbix/zabbix_server.conf.bak  # Criar backup
    sed -i "s/^\s*DBPassword\s*=\s*.*/DBPassword=$ZABBIX_USER_PASSWORD/" /etc/zabbix/zabbix_server.conf || { echo -e "\e[31mErro ao atualizar configuração do Zabbix\e[0m"; exit 1; }
else
    echo -e "\e[31mArquivo de configuração do Zabbix não encontrado: /etc/zabbix/zabbix_server.conf\e[0m"
    exit 1
fi

# Instalar e configurar Grafana
echo "Instalando Grafana e plugin do Zabbix..."
wget "https://dl.grafana.com/enterprise/release/grafana-enterprise_9.5.3_amd64.deb" -O /tmp/grafana.deb &>/dev/null
dpkg -i /tmp/grafana.deb || { echo -e "\e[31mErro ao instalar o pacote do Grafana\e[0m"; exit 1; }
apt-get install -f -y &>/dev/null || { echo -e "\e[31mErro ao corrigir dependências do Grafana\e[0m"; exit 1; }
grafana-cli plugins install alexanderzobnin-zabbix-app || { echo -e "\e[31mErro ao instalar o plugin Zabbix no Grafana\e[0m"; exit 1; }
systemctl enable grafana-server && systemctl restart grafana-server

# Configurar datasource do Zabbix no Grafana com tempo de espera para garantir que o serviço esteja pronto
echo "Aguardando Grafana iniciar para configurar o datasource..."
sleep 10
curl -X POST -H "Content-Type: application/json" -d '{
  "name": "Zabbix",
  "type": "alexanderzobnin-zabbix-datasource",
  "access": "proxy",
  "url": "http://localhost/zabbix",
  "basicAuth": false,
  "jsonData": {
    "zabbixApiUrl": "http://localhost/zabbix/api_jsonrpc.php",
    "zabbixApiLogin": "'"$DB_USER"'",
    "zabbixApiPassword": "'"$ZABBIX_USER_PASSWORD"'"
  }
}' http://admin:admin@localhost:3000/api/datasources || { echo -e "\e[31mErro ao configurar o datasource do Zabbix no Grafana\e[0m"; }

# Mensagem final com informações de acesso em verde fluorescente
clear
echo -e "\e[1;32mInstalação concluída com sucesso!\e[0m"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Acesse o Zabbix na URL: http://$SERVER_IP/zabbix"
echo "Acesse o Grafana na URL: http://$SERVER_IP:3000"
echo "A senha do usuário Zabbix para o banco de dados é: $ZABBIX_USER_PASSWORD"
