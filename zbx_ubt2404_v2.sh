#!/bin/bash

set -e  # Parar o script na primeira ocorrência de erro

# Função para exibir a barra de progresso
loading_message() {
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

# Função para configurar o plugin Zabbix no Grafana
configure_grafana_zabbix_plugin() {
    echo "Configurando o plugin Zabbix no Grafana..."
    # Configuração do Grafana com plugin Zabbix
    # Este é um exemplo genérico, ajuste conforme sua configuração:
    cat <<EOF > /etc/grafana/provisioning/dashboards/zabbix.json
{
  "apiVersion": 1,
  "providers": [
    {
      "name": "Zabbix",
      "orgId": 1,
      "folder": "Zabbix Dashboards",
      "type": "file",
      "options": {
        "path": "/var/lib/grafana/dashboards/zabbix"
      }
    }
  ]
}
EOF
    systemctl restart grafana-server || error_message "Erro ao reiniciar o Grafana"
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
loading_message "Removendo instalações anteriores" 3
remove_existing || error_message "Falha ao remover instalações anteriores"

# Configurar timezone e locale
loading_message "Configurando timezone e locale" 3
timedatectl set-timezone "America/Sao_Paulo" || error_message "Falha ao configurar o timezone"
locale-gen "pt_BR.UTF-8" > /dev/null 2>&1 || error_message "Falha ao gerar locale"
update-locale LANG="pt_BR.UTF-8" > /dev/null 2>&1 || error_message "Falha ao atualizar locale"

# Instalar pacotes necessários
loading_message "Atualizando o sistema e instalando pacotes" 3
apt update -y > /dev/null 2>&1 || error_message "Falha ao atualizar pacotes"
apt install -y wget gnupg2 software-properties-common mysql-server nano > /dev/null 2>&1 || error_message "Falha ao instalar pacotes necessários"

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
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;" || error_message "Erro ao criar o banco de dados"
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_USER_PASSWORD';" || error_message "Erro ao criar o usuário"
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" || error_message "Erro ao conceder permissões ao usuário"
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;" || error_message "Erro ao aplicar privilégios"

# Instalar Zabbix
loading_message "Instalando Zabbix" 3
wget "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb" -O /tmp/zabbix-release.deb > /dev/null 2>&1
dpkg -i /tmp/zabbix-release.deb > /dev/null 2>&1 || error_message "Erro ao instalar o pacote do Zabbix"
apt update -y > /dev/null 2>&1
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent zabbix-sql-scripts > /dev/null 2>&1 || error_message "Erro ao instalar pacotes do Zabbix"

# Importar esquema inicial
loading_message "Importando esquema inicial para o banco de dados Zabbix" 3
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_NAME" 2>/dev/null || error_message "Erro ao importar esquema inicial"

# Atualizar configuração do Zabbix
loading_message "Atualizando configuração do Zabbix" 3
if [ -f /etc/zabbix/zabbix_server.conf ]; then
    cp /etc/zabbix/zabbix_server.conf /etc/zabbix/zabbix_server.conf.bak  # Criar backup
    sed -i "s/^#\? DBPassword=.*/DBPassword=$ZABBIX_USER_PASSWORD/" /etc/zabbix/zabbix_server.conf || error_message "Erro ao atualizar configuração do Zabbix"
else
    error_message "Arquivo de configuração do Zabbix não encontrado: /etc/zabbix/zabbix_server.conf"
fi

# Reiniciar serviços do MySQL
loading_message "Reiniciando serviços do MySQL" 3
systemctl restart mysql || error_message "Erro ao reiniciar o MySQL"

# Instalar Grafana e plugin Zabbix
loading_message "Instalando Grafana e plugin do Zabbix" 3
wget "https://dl.grafana.com/enterprise/release/grafana-enterprise_9.5.3_amd64.deb" -O /tmp/grafana.deb > /dev/null 2>&1
dpkg -i /tmp/grafana.deb > /dev/null 2>&1 || error_message "Erro ao instalar o pacote do Grafana"
apt-get install -f -y > /dev/null 2>&1 || error_message "Erro ao corrigir dependências"
grafana-cli plugins install alexanderzobnin-zabbix-app > /dev/null 2>&1 || error_message "Erro ao instalar plugin Zabbix no Grafana"

# Configuração automática do plugin Zabbix no Grafana
configure_grafana_zabbix_plugin

# Reiniciar serviços do Zabbix e Grafana
loading_message "Reiniciando serviços do Zabbix e Grafana" 3
systemctl restart zabbix-server zabbix-agent apache2 grafana-server || error_message "Erro ao reiniciar serviços"

# Mensagem final com logo do Zabbix
clear
echo "Z$Z$Z$Z"
echo "Z$Z$Z$Z"
echo "Z$Z$Z$Z"
echo "Z$Z$Z$Z"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Acesse o Zabbix na URL: http://$SERVER_IP/zabbix"
echo "Acesse o Grafana na URL: http://$SERVER_IP:3000"
echo "Senha do usuário Zabbix para o banco de dados: $ZABBIX_USER_PASSWORD"
