#!/bin/bash

# Variáveis
ZABBIX_VERSION="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb"
TIMEZONE="America/Sao_Paulo"
LOCALE="pt_BR.UTF-8"
DB_NAME="zabbix_db"
DB_USER="zabbix_user"
GRAFANA_VERSION="https://dl.grafana.com/enterprise/release/grafana-enterprise_9.5.3_amd64.deb"

# Função para remover o Zabbix e Grafana, se existirem
remove_existing() {
    echo "Removendo Zabbix e Grafana existentes..."
    systemctl stop zabbix-server zabbix-agent apache2 grafana-server
    apt-get purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent grafana
    apt-get autoremove -y
}

# Função de tratamento de erro com mensagem personalizada
handle_error() {
    clear
    echo -e "\033[1;31mErro:\033[0m $1"
    exit 1
}

# Verificar se o script está sendo executado como root
if [[ "$EUID" -ne 0 ]]; then
    handle_error "Por favor, execute este script como root."
fi

# Remover instalação anterior do Zabbix e Grafana, se houver
remove_existing

# Configurar timezone e locale
echo "Configurando timezone e locale..."
timedatectl set-timezone "$TIMEZONE" || handle_error "Falha ao definir o timezone."
locale-gen $LOCALE
update-locale LANG=$LOCALE || handle_error "Falha ao configurar o locale."

# Instalar pacotes necessários
echo "Atualizando sistema e instalando pré-requisitos..."
apt update -y
apt install -y wget gnupg2 software-properties-common mysql-server || handle_error "Erro ao instalar pacotes necessários."

# Limpar a tela antes de solicitar as senhas
clear

# Solicitar senha do root do MySQL e do usuário do Zabbix
read -s -p "Insira a senha do root do MySQL: " MYSQL_ROOT_PASSWORD
echo
clear
read -s -p "Insira a senha para o usuário do Zabbix: " ZABBIX_USER_PASSWORD
echo
clear

# Criar um arquivo de configuração temporário para o MySQL
MYSQL_CNF=$(mktemp)
echo "[client]" > "$MYSQL_CNF"
echo "user=root" >> "$MYSQL_CNF"
echo "password=$MYSQL_ROOT_PASSWORD" >> "$MYSQL_CNF"

# Verificar se o banco de dados e o usuário já existem e remover se necessário
DB_EXIST=$(mysql --defaults-file="$MYSQL_CNF" -e "SHOW DATABASES LIKE '$DB_NAME';" 2>/dev/null)
if [[ -n "$DB_EXIST" ]]; then
    echo "O banco de dados '$DB_NAME' já existe. Removendo..."
    mysql --defaults-file="$MYSQL_CNF" -e "DROP DATABASE $DB_NAME;" || handle_error "Erro ao remover o banco de dados."
fi

USER_EXIST=$(mysql --defaults-file="$MYSQL_CNF" -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '$DB_USER');" 2>/dev/null)
if [[ "$USER_EXIST" == *"1"* ]]; then
    echo "O usuário '$DB_USER' já existe. Removendo..."
    mysql --defaults-file="$MYSQL_CNF" -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" || handle_error "Erro ao remover o usuário."
fi

# Criar banco de dados e usuário do Zabbix
echo "Criando banco de dados e usuário do Zabbix..."
mysql --defaults-file="$MYSQL_CNF" -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;" || handle_error "Erro ao criar o banco de dados."
mysql --defaults-file="$MYSQL_CNF" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_USER_PASSWORD';" || handle_error "Erro ao criar o usuário."
mysql --defaults-file="$MYSQL_CNF" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" || handle_error "Erro ao conceder privilégios."
mysql --defaults-file="$MYSQL_CNF" -e "FLUSH PRIVILEGES;" || handle_error "Erro ao atualizar privilégios."

# Instalar Zabbix
echo "Instalando Zabbix..."
wget "$ZABBIX_VERSION" -O /tmp/zabbix-release.deb || handle_error "Erro ao baixar o pacote Zabbix."
dpkg -i /tmp/zabbix-release.deb || handle_error "Erro ao instalar o pacote Zabbix."
apt update -y
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent zabbix-sql-scripts || handle_error "Erro ao instalar Zabbix."

# Verificar e localizar o arquivo SQL
ZABBIX_SQL_FILE="/usr/share/zabbix-sql-scripts/mysql/server.sql.gz"
if [[ ! -f "$ZABBIX_SQL_FILE" ]]; then
    echo "Arquivo SQL não encontrado em '$ZABBIX_SQL_FILE'. Verificando outros arquivos no diretório..."
    ls /usr/share/zabbix-sql-scripts/mysql/
    handle_error "Arquivo SQL para Zabbix não encontrado. Verifique a instalação do Zabbix."
fi

# Importar o esquema inicial para o banco de dados Zabbix
echo "Importando esquema inicial para o banco de dados Zabbix..."
zcat "$ZABBIX_SQL_FILE" | mysql --defaults-file="$MYSQL_CNF" --default-character-set=utf8mb4 -u"$DB_USER" -p"$ZABBIX_USER_PASSWORD" "$DB_NAME" || handle_error "Erro ao importar o esquema do banco de dados Zabbix."

# Atualizar configuração do Zabbix
echo "Atualizando configuração do Zabbix..."
sed -i "s/^DBPassword=.*/DBPassword='$ZABBIX_USER_PASSWORD'/" /etc/zabbix/zabbix_server.conf

# Reiniciar serviços do Zabbix
echo "Reiniciando serviços do Zabbix..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

# Instalar Grafana
echo "Instalando Grafana..."
wget "$GRAFANA_VERSION" -O /tmp/grafana.deb || handle_error "Erro ao baixar o pacote Grafana."
dpkg -i /tmp/grafana.deb || handle_error "Erro ao instalar o pacote Grafana."
apt-get install -f -y || handle_error "Erro ao corrigir dependências do Grafana."

# Reiniciar e habilitar o serviço do Grafana
echo "Reiniciando serviços do Grafana..."
systemctl enable --now grafana-server || handle_error "Erro ao habilitar o Grafana."

# Remover o arquivo de configuração temporário
rm -f "$MYSQL_CNF"

# Finalização
clear
echo "############################################################"
echo "Instalação do Zabbix e Grafana concluída com sucesso."
echo "Acesse o Zabbix na URL: http://<IP_DO_SEU_SERVIDOR>/zabbix"
echo "Acesse o Grafana na URL: http://<IP_DO_SEU_SERVIDOR>:3000"
echo "############################################################"
