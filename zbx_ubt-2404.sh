#!/bin/bash

# Função para remover Zabbix e Grafana, se existente
remove_existing() {
    echo "Removendo Zabbix e Grafana existentes..."
    systemctl stop zabbix-server zabbix-agent apache2 grafana-server
    apt-get purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent grafana nano
    apt-get autoremove -y
}

# Solicitar o nome do banco de dados e do usuário
read -p "Digite o nome do banco de dados a ser criado (padrão: zabbix_db): " DB_NAME
DB_NAME=${DB_NAME:-zabbix_db}
read -p "Digite o nome do usuário do banco de dados (padrão: zabbix_user): " DB_USER
DB_USER=${DB_USER:-zabbix_user}

# Solicitar senhas
clear
read -s -p "Insira a senha do root do MySQL: " MYSQL_ROOT_PASSWORD
echo
read -s -p "Insira a senha para o usuário do Zabbix: " ZABBIX_USER_PASSWORD
echo

# Variáveis de versão e configuração
ZABBIX_VERSION="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb"
TIMEZONE="America/Sao_Paulo"
LOCALE="pt_BR.UTF-8"
GRAFANA_VERSION="https://dl.grafana.com/enterprise/release/grafana-enterprise_9.5.3_amd64.deb"

# Verificação de permissão de root
if [[ "$EUID" -ne 0 ]]; then
    echo "Por favor, execute este script como root."
    exit 1
fi

# Remover instalação anterior
remove_existing

# Configurar timezone e locale
echo "Configurando timezone e locale..."
timedatectl set-timezone "$TIMEZONE"
locale-gen "$LOCALE"
update-locale LANG="$LOCALE"

# Instalar pacotes necessários
echo "Atualizando sistema e instalando pré-requisitos..."
apt update -y
apt install -y wget gnupg2 software-properties-common mysql-server nano

# Verificar e excluir banco e usuário existentes, se necessário
echo "Verificando se o banco e o usuário já existem..."
DB_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES LIKE '$DB_NAME';" 2>/dev/null)
if [[ -n "$DB_EXIST" ]]; then
    echo "O banco de dados '$DB_NAME' já existe. Removendo..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE $DB_NAME;" || { echo "Erro ao remover o banco de dados"; exit 1; }
fi

USER_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '$DB_USER');" 2>/dev/null)
if [[ "$USER_EXIST" == *"1"* ]]; then
    echo "O usuário '$DB_USER' já existe. Removendo..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP USER '$DB_USER'@'localhost';" || { echo "Erro ao remover o usuário"; exit 1; }
fi

# Criar banco de dados e usuário
echo "Criando banco de dados e usuário do Zabbix..."
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;" || { echo "Erro ao criar o banco de dados"; exit 1; }
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_USER_PASSWORD';" || { echo "Erro ao criar o usuário"; exit 1; }
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" || { echo "Erro ao conceder permissões ao usuário"; exit 1; }
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;" || { echo "Erro ao aplicar privilégios"; exit 1; }

# Instalar Zabbix
echo "Instalando Zabbix..."
wget "$ZABBIX_VERSION" -O /tmp/zabbix-release.deb
dpkg -i /tmp/zabbix-release.deb || { echo "Erro ao instalar o pacote do Zabbix"; exit 1; }
apt update -y
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent zabbix-sql-scripts || { echo "Erro ao instalar os pacotes do Zabbix"; exit 1; }

# Importar esquema inicial
echo "Importando esquema inicial para o banco de dados Zabbix..."
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_NAME" || { echo "Erro ao importar esquema inicial"; exit 1; }

# Atualizar configuração do Zabbix
echo "Atualizando configuração do Zabbix..."
echo "Senha do Zabbix: $ZABBIX_USER_PASSWORD"  # Para verificar se a variável está definida
sed -i 's/^DBPassword=.*/DBPassword='"$ZABBIX_USER_PASSWORD"'/' /etc/zabbix/zabbix_server.conf || { echo "Erro ao atualizar configuração do Zabbix"; exit 1; }

# Instalar Grafana e plugin Zabbix
echo "Instalando Grafana e plugin do Zabbix..."
wget "$GRAFANA_VERSION" -O /tmp/grafana.deb
dpkg -i /tmp/grafana.deb || { echo "Erro ao instalar o pacote do Grafana"; exit 1; }
apt-get install -f -y || { echo "Erro ao corrigir dependências"; exit 1; }
grafana-cli plugins install alexanderzobnin-zabbix-app || { echo "Erro ao instalar o plugin Zabbix no Grafana"; exit 1; }
systemctl enable --now grafana-server

# Redefinir senha do usuário do Zabbix após instalação
echo "Redefinindo senha do usuário Zabbix..."
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_USER_PASSWORD';" || { echo "Erro ao redefinir senha do usuário Zabbix"; exit 1; }

# Conceder permissões novamente ao usuário Zabbix
echo "Concedendo permissões ao usuário Zabbix..."
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;" || { echo "Erro ao conceder permissões ao usuário Zabbix"; exit 1; }

# Reiniciar serviços do MySQL
echo "Reiniciando serviços do MySQL..."
systemctl restart mysql || { echo "Erro ao reiniciar o MySQL"; exit 1; }

# Reiniciar Zabbix
systemctl restart zabbix-server zabbix-agent apache2 || { echo "Erro ao reiniciar serviços do Zabbix"; exit 1; }
systemctl enable zabbix-server zabbix-agent apache2

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
