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

# Verificar se o banco de dados e o usuário já existem e remover se necessário
DB_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES LIKE '$DB_NAME';" 2>/dev/null)
if [[ -n "$DB_EXIST" ]]; then
    echo "O banco de dados '$DB_NAME' já existe. Removendo..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE $DB_NAME;" || handle_error "Erro ao remover o banco de dados."
fi

USER_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '$DB_USER');" 2>/dev/null)
if [[ "$USER_EXIST" == *"1"* ]]; then
    echo "O usuário '$DB_USER' já existe. Removendo..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" || handle_error "Erro ao remover o usuário."
fi

# Criar banco de dados e usuário do Zabbix
echo "Criando banco de dados e usuário do Zabbix..."
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;" || handle_error "Erro ao criar o banco de dados."
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_USER_PASSWORD';" || handle_error "Erro ao criar o usuário."
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" || handle_error "Erro ao conceder privilégios."
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;" || handle_error "Erro ao atualizar privilégios."

# Instalar Zabbix
echo "Instalando Zabbix..."
wget "$ZABBIX_VERSION" -O /tmp/zabbix-release.deb || handle_error "Erro ao baixar o pacote Zabbix."
dpkg -i /tmp/zabbix-release.deb || handle_error "Erro ao instalar o pacote Zabbix."
apt update -y
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent || handle_error "Erro ao instalar Zabbix."

# Verificação do arquivo SQL
echo "Verificando o arquivo SQL do Zabbix..."
SQL_PATHS=(
    "/usr/share/zabbix-sql-scripts/mysql/server.sql.gz"
    "/usr/share/doc/zabbix-server-mysql/create.sql.gz"
)
ZABBIX_SQL_FILE=""

# Procurar pelo arquivo SQL
for path in "${SQL_PATHS[@]}"; do
    if [[ -f "$path" ]]; then
        ZABBIX_SQL_FILE="$path"
        break
    fi
done

# Verificar se o arquivo foi encontrado
if [[ -z "$ZABBIX_SQL_FILE" ]]; then
    handle_error "Arquivo SQL para Zabbix não encontrado. Verifique a instalação do Zabbix."
else
    echo "Arquivo SQL encontrado em: $ZABBIX_SQL_FILE"
fi

# Importar o esquema inicial para o banco de dados Zabbix
echo "Importando esquema inicial para o banco de dados Zabbix..."
zcat "$ZABBIX_SQL_FILE" | mysql --default-character-set=utf8mb4 -u"$DB_USER" -p"$ZABBIX_USER_PASSWORD" "$DB_NAME" || handle_error "Erro ao importar o esquema do banco de dados Zabbix."

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

# Finalização
echo "Instalação do Zabbix e Grafana concluída com sucesso."
echo "Acesse o Zabbix na URL: http://<IP_DO_SEU_SERVIDOR>/zabbix"
echo "Acesse o Grafana na URL: http://<IP_DO_SEU_SERVIDOR>:3000"
