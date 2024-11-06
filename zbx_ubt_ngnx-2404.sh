#!/bin/bash

set -e  # Parar o script na primeira ocorrência de erro

# Função para exibir animação de loading
loading_message() {
    local message="$1"
    local duration=${2:-3}
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
    tput setaf 1
    echo "Erro: $message"
    tput sgr0
    exit 1
}

# Função para remover Zabbix e Grafana, se existente
remove_existing() {
    echo "Removendo instalações anteriores de Zabbix e Grafana..."
    systemctl stop zabbix-server zabbix-agent nginx grafana-server || true
    apt-get purge -y zabbix-server-mysql zabbix-frontend-php zabbix-nginx-conf zabbix-agent grafana nano > /dev/null 2>&1 || true
    apt-get autoremove -y > /dev/null 2>&1 || true
}

clear

# Verificar e instalar o toilet
if ! command -v toilet &> /dev/null; then
    loading_message "Instalando o toilet para exibir mensagens" 3
    apt update -y > /dev/null 2>&1 || error_message "Falha ao atualizar pacotes para instalar o toilet"
    apt install -y toilet > /dev/null 2>&1 || error_message "Falha ao instalar o toilet"
fi

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
loading_message "Removendo instalações anteriores" 3
remove_existing || error_message "Falha ao remover instalações anteriores"

# Limpar o cache do APT e atualizar o sistema
loading_message "Limpando o cache do APT e atualizando pacotes" 3
rm -rf /var/lib/apt/lists/* || error_message "Erro ao limpar o cache do APT"

# Diagnóstico detalhado da atualização
loading_message "Tentando atualizar pacotes do sistema" 3
apt update -y || {
    echo ""
    echo ">>> Diagnóstico detalhado do erro de atualização <<<"
    echo ""
    echo "1. Repositórios no arquivo '/etc/apt/sources.list':"
    cat /etc/apt/sources.list
    echo ""
    echo "2. Arquivos de repositórios adicionais na pasta '/etc/apt/sources.list.d/':"
    ls /etc/apt/sources.list.d/
    echo ""
    echo "Sugestões para solução:"
    echo "- Verifique se os repositórios no arquivo '/etc/apt/sources.list' estão acessíveis e corretos."
    echo "- Tente rodar manualmente 'apt update' para identificar o erro exato."
    echo "- Verifique arquivos adicionais em '/etc/apt/sources.list.d/' e remova ou atualize repositórios problemáticos."
    error_message "Falha ao atualizar pacotes. Verifique os repositórios e tente novamente."
}

# Instalar pacotes necessários
loading_message "Instalando pacotes necessários" 3
apt install -y wget gnupg2 software-properties-common mysql-server nano || error_message "Falha ao instalar pacotes necessários"

# Verificar e excluir banco e usuário existentes, se necessário
loading_message "Verificando banco de dados e usuário" 3
DB_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES LIKE '$DB_NAME';" 2>/dev/null || true)
if [[ -n "$DB_EXIST" ]]; then
    loading_message "Removendo banco de dados existente" 3
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE $DB_NAME;" || error_message "Erro ao remover o banco de dados"
fi

USER_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '$DB_USER');" 2>/dev/null || true)
if [[ "$USER_EXIST" == *"1"* ]]; then
    loading_message "Removendo usuário existente" 3
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP USER '$DB_USER'@'localhost';" || error_message "Erro ao remover o usuário"
fi

# Criar banco de dados e usuário
loading_message "Criando banco de dados e usuário do Zabbix" 3
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;" || error_message "Erro ao criar o banco de dados"
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_USER_PASSWORD';" || error_message "Erro ao criar o usuário"
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" || error_message "Erro ao conceder permissões ao usuário"
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;" || error_message "Erro ao aplicar privilégios"

# Instalar Zabbix
loading_message "Instalando Zabbix" 3
wget "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb" -O /tmp/zabbix-release.deb > /dev/null 2>&1
dpkg -i /tmp/zabbix-release.deb > /dev/null 2>&1 || error_message "Erro ao instalar o pacote do Zabbix"
apt update -y > /dev/null 2>&1
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-nginx-conf zabbix-sql-scripts zabbix-agent || error_message "Erro ao instalar pacotes do Zabbix"

# Importar esquema inicial
loading_message "Importando esquema inicial para o banco de dados Zabbix" 3
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_NAME" || error_message "Erro ao importar esquema inicial"

# Atualizar configuração do Zabbix
loading_message "Atualizando configuração do Zabbix" 3
if [ -f /etc/zabbix/zabbix_server.conf ]; then
    cp /etc/zabbix/zabbix_server.conf /etc/zabbix/zabbix_server.conf.bak
    sed -i "s/^#\? DBPassword=.*/DBPassword=$ZABBIX_USER_PASSWORD/" /etc/zabbix/zabbix_server.conf || error_message "Erro ao atualizar configuração do Zabbix"
else
    error_message "Arquivo de configuração do Zabbix não encontrado: /etc/zabbix/zabbix_server.conf"
fi

# Configurar PHP e NGINX para o Zabbix frontend
loading_message "Configurando PHP e NGINX para o frontend do Zabbix" 3
if [ -f /etc/zabbix/nginx.conf ]; then
    cp /etc/zabbix/nginx.conf /etc/zabbix/nginx.conf.bak
    sed -i "s/# listen 8080;/listen 8080;/" /etc/zabbix/nginx.conf
    sed -i "s/# server_name example.com;/server_name localhost;/" /etc/zabbix/nginx.conf
else
    error_message "Arquivo de configuração NGINX para Zabbix não encontrado: /etc/zabbix/nginx.conf"
fi

# Reiniciar serviços
loading_message "Reiniciando serviços do Zabbix" 3
systemctl restart zabbix-server zabbix-agent nginx php8.3-fpm || error_message "Erro ao reiniciar serviços do Zabbix"
systemctl enable zabbix-server zabbix-agent nginx php8.3-fpm

# Mensagem final
clear
toilet -f standard --gay "Instalação concluída com sucesso!"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Acesse o Zabbix na URL: http://$SERVER_IP:8080/zabbix"
echo "Acesse o Grafana na URL: http://$SERVER_IP:3000"
echo "Senha do usuário Zabbix para o banco de dados: $ZABBIX_USER_PASSWORD"
