#!/bin/bash

set -e  # Para parar o script na primeira ocorrência de erro

# Função para exibir a barra de progresso
progress() {
    local percentage=$1
    echo -ne "\r[$(printf "%-50s" | tr ' ' '#')${percentage}%]"
}

# Função para executar um comando e exibir a barra de progresso
execute_step() {
    local description=$1
    shift
    echo "$description"
    "$@" &>/dev/null &
    local pid=$!
    local progress_bar=0

    while kill -0 "$pid" &>/dev/null; do
        sleep 0.1
        progress_bar=$((progress_bar + 2))
        [ $progress_bar -gt 100 ] && progress_bar=0
        progress $progress_bar
    done

    wait "$pid"
    if [ $? -ne 0 ]; then
        echo -e "\e[31m\nErro na etapa: $description\e[0m"
        exit 1
    fi
    echo -e "\e[32m\nConcluído.\e[0m"
}

# Função para remover Zabbix e Grafana, se existente
remove_existing() {
    echo "Removendo Zabbix e Grafana existentes..."
    systemctl stop zabbix-server zabbix-agent apache2 grafana-server || true
    execute_step "Removendo pacotes..." apt-get purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent grafana
    execute_step "Removendo pacotes não utilizados..." apt-get autoremove -y
}

# Verificação de permissão de root
if [[ "$EUID" -ne 0 ]]; then
    echo -e "\e[31mPor favor, execute este script como root.\e[0m"
    exit 1
fi

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

# Remover instalação anterior
remove_existing

# Configurar timezone e locale
execute_step "Configurando timezone e locale..." timedatectl set-timezone "America/Sao_Paulo" && locale-gen "pt_BR.UTF-8" && update-locale LANG="pt_BR.UTF-8"

# Instalar pacotes necessários
execute_step "Atualizando sistema e instalando pré-requisitos..." apt update -y && apt install -y wget gnupg2 software-properties-common mysql-server nano

# Verificar e excluir banco e usuário existentes, se necessário
echo "Verificando e configurando banco de dados..."
DB_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES LIKE '$DB_NAME';" 2>/dev/null || true)
if [[ -n "$DB_EXIST" ]]; then
    echo "O banco de dados '$DB_NAME' já existe. Removendo..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE $DB_NAME;" || { echo -e "\e[31mErro ao remover o banco de dados\e[0m"; exit 1; }
fi

USER_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '$DB_USER');" 2>/dev/null || true)
if [[ "$USER_EXIST" == *"1"* ]]; then
    echo "O usuário '$DB_USER' já existe. Removendo..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP USER '$DB_USER'@'localhost';" || { echo -e "\e[31mErro ao remover o usuário\e[0m"; exit 1; }
fi

# Criar banco de dados e usuário
execute_step "Criando banco de dados e usuário do Zabbix..." \
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;" && \
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_USER_PASSWORD';" && \
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;"

# Instalar Zabbix
execute_step "Instalando Zabbix..." \
    wget "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb" -O /tmp/zabbix-release.deb && \
    dpkg -i /tmp/zabbix-release.deb && \
    apt update -y && \
    apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent zabbix-sql-scripts

# Importar esquema inicial para o banco de dados Zabbix
echo "Importando esquema inicial para o banco de dados Zabbix..."
execute_step "Importando esquema inicial..." \
    zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_NAME"

# Atualizar configuração do Zabbix
echo "Atualizando configuração do Zabbix..."
if [ -f /etc/zabbix/zabbix_server.conf ]; then
    cp /etc/zabbix/zabbix_server.conf /etc/zabbix/zabbix_server.conf.bak
    if grep -q "^\s*DBPassword\s*=" /etc/zabbix/zabbix_server.conf; then
        sed -i "s/^\s*DBPassword\s*=.*/DBPassword=$ZABBIX_USER_PASSWORD/" /etc/zabbix/zabbix_server.conf || { echo -e "\e[31mErro ao atualizar configuração do Zabbix\e[0m"; exit 1; }
    else
        echo "DBPassword=$ZABBIX_USER_PASSWORD" >> /etc/zabbix/zabbix_server.conf || { echo -e "\e[31mErro ao adicionar configuração DBPassword no Zabbix\e[0m"; exit 1; }
    fi
    echo -e "\e[32mConfiguração do Zabbix atualizada com sucesso.\e[0m"
else
    echo -e "\e[31mArquivo de configuração do Zabbix não encontrado: /etc/zabbix/zabbix_server.conf\e[0m"
    exit 1
fi

# Reiniciar serviços do MySQL
execute_step "Reiniciando serviços do MySQL..." systemctl restart mysql

# Instalar Grafana e plugin Zabbix
execute_step "Instalando Grafana e plugin do Zabbix..." \
    wget "https://dl.grafana.com/enterprise/release/grafana-enterprise_9.5.3_amd64.deb" -O /tmp/grafana.deb && \
    dpkg -i /tmp/grafana.deb && \
    apt-get install -f -y && \
    grafana-cli plugins install alexanderzobnin-zabbix-app

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
