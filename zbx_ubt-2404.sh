#!/bin/bash

set -e  # Parar o script na primeira ocorrência de erro

# Função para exibir barra de progresso
progress_bar() {
    local message="$1"
    local duration=${2:-3}  # Tempo de exibição da barra de progresso
    echo -n "$message"
    for ((i=0; i<$duration; i++)); do
        echo -n "."
        sleep 1
    done
    echo ""
}

# Função para exibir mensagens de erro em vermelho
error_message() {
    local message="$1"
    tput setaf 1  # Mudar texto para vermelho
    echo "Erro: $message"
    tput sgr0     # Voltar à cor padrão
    exit 1
}

# Função para remover Zabbix e Grafana, se existente
remove_existing() {
    echo "Removendo instalações anteriores de Zabbix e Grafana..."
    systemctl stop zabbix-server zabbix-agent apache2 grafana-server || true
    apt-get purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent grafana nano > /dev/null 2>&1 || true
    apt-get autoremove -y > /dev/null 2>&1 || true
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

clear
# Verificação de permissão de root
if [[ "$EUID" -ne 0 ]]; then
    error_message "Por favor, execute este script como root."
fi

# Remover instalação anterior
progress_bar "Removendo instalações anteriores" 3
remove_existing || error_message "Falha ao remover instalações anteriores"

# Configurar timezone e locale
progress_bar "Configurando timezone e locale" 3
timedatectl set-timezone "America/Sao_Paulo" || error_message "Falha ao configurar o timezone"
locale-gen "pt_BR.UTF-8" > /dev/null 2>&1 || error_message "Falha ao gerar locale"
update-locale LANG="pt_BR.UTF-8" > /dev/null 2>&1 || error_message "Falha ao atualizar locale"

# Instalar pacotes necessários
progress_bar "Atualizando o sistema e instalando pacotes" 3
apt update -y > /dev/null 2>&1 || error_message "Falha ao atualizar pacotes"
apt install -y wget gnupg2 software-properties-common mysql-server nano > /dev/null 2>&1 || error_message "Falha ao instalar pacotes necessários"

# Verificar e excluir banco e usuário existentes, se necessário
progress_bar "Verificando banco de dados e usuário" 3
DB_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES LIKE '$DB_NAME';" 2>/dev/null || true)
if [[ -n "$DB_EXIST" ]]; then
    progress_bar "Removendo banco de dados existente" 3
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE $DB_NAME;" || error_message "Erro ao remover o banco de dados"
fi

USER_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '$DB_USER');" 2>/dev/null || true)
if [[ "$USER_EXIST" == *"1"* ]]; then
    progress_bar "Removendo usuário existente" 3
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP USER '$DB_USER'@'localhost';" || error_message "Erro ao remover o usuário"
fi

# Criar banco de dados e usuário
progress_bar "Criando banco de dados e usuário do Zabbix" 3
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;" || error_message "Erro ao criar o banco de dados"
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_USER_PASSWORD';" || error_message "Erro ao criar o usuário"
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" || error_message "Erro ao conceder permissões ao usuário"
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;" || error_message "Erro ao aplicar privilégios"

# Instalar Zabbix
progress_bar "Instalando Zabbix" 3
wget "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb" -O /tmp/zabbix-release.deb > /dev/null 2>&1
dpkg -i /tmp/zabbix-release.deb > /dev/null 2>&1 || error_message "Erro ao instalar o pacote do Zabbix"
apt update -y > /dev/null 2>&1
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent zabbix-sql-scripts > /dev/null 2>&1 || error_message "Erro ao instalar pacotes do Zabbix"

# Importar esquema inicial
progress_bar "Importando esquema inicial para o banco de dados Zabbix" 3
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_NAME" || error_message "Erro ao importar esquema inicial"

# Atualizar configuração do Zabbix
loading_message "Atualizando configuração do Zabbix" 3

if [ -f /etc/zabbix/zabbix_server.conf ]; then
    cp /etc/zabbix/zabbix_server.conf /etc/zabbix/zabbix_server.conf.bak  # Criar backup
    
    # Atualiza o valor de DBPassword, tratando linhas comentadas ou não
    sed -i "s/^#\? DBPassword=.*/DBPassword=$ZABBIX_USER_PASSWORD/" /etc/zabbix/zabbix_server.conf || error_message "Erro ao atualizar configuração do Zabbix"
    
    echo "Configuração do Zabbix atualizada com sucesso."
else
    error_message "Arquivo de configuração do Zabbix não encontrado: /etc/zabbix/zabbix_server.conf"
fi

# Reiniciar serviços do MySQL
progress_bar "Reiniciando serviços do MySQL" 3
systemctl restart mysql || error_message "Erro ao reiniciar o MySQL"

# Instalar Grafana e plugin Zabbix
progress_bar "Instalando Grafana e plugin do Zabbix" 3
wget "https://dl.grafana.com/enterprise/release/grafana-enterprise_9.5.3_amd64.deb" -O /tmp/grafana.deb > /dev/null 2>&1
dpkg -i /tmp/grafana.deb > /dev/null 2>&1 || error_message "Erro ao instalar o pacote do Grafana"
apt-get install -f -y > /dev/null 2>&1 || error_message "Erro ao corrigir dependências"
grafana-cli plugins install alexanderzobnin-zabbix-app > /dev/null 2>&1 || error_message "Erro ao instalar plugin Zabbix no Grafana"

# Configuração automática do plugin Zabbix no Grafana
configure_grafana_zabbix_plugin() {
    echo "Configurando o plugin Zabbix no Grafana..."
    
    # Definindo o URL e as credenciais de acesso ao Zabbix
    ZABBIX_URL="http://$SERVER_IP/zabbix"
    ZABBIX_API_USER="Admin"
    ZABBIX_API_PASS="zabbix"  # Altere para a senha desejada ou conforme necessário

    # Adicionando a fonte de dados do Zabbix no Grafana via API
    curl -s -X POST -H "Content-Type: application/json" \
        -d '{
            "name": "Zabbix",
            "type": "alexanderzobnin-zabbix-datasource",
            "url": "'"$ZABBIX_URL"'",
            "access": "proxy",
            "basicAuth": false,
            "jsonData": {
                "username": "'"$ZABBIX_API_USER"'",
                "password": "'"$ZABBIX_API_PASS"'",
                "zabbixVersion": 5.0
            }
        }' http://localhost:3000/api/datasources
}

configure_grafana_zabbix_plugin

# Reiniciar serviços
progress_bar "Reiniciando serviços do Zabbix" 3
systemctl restart zabbix-server zabbix-agent apache2 || error_message "Erro ao reiniciar serviços do Zabbix"

progress_bar "Reiniciando serviço do Grafana" 3
systemctl restart grafana-server || error_message "Erro ao reiniciar o serviço do Grafana"

# Mensagem final com o logo do ZABBIX
clear
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Acesse o Zabbix na URL: http://$SERVER_IP/zabbix"
echo "Acesse o Grafana na URL: http://$SERVER_IP:3000"
echo "Senha do usuário Zabbix para o banco de dados: $ZABBIX_USER_PASSWORD"
