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

# Função para verificar se o Grafana está ouvindo na porta 3000
check_grafana_port() {
    echo "Verificando se o Grafana está ouvindo na porta 3000..."
    if ! ss -tuln | grep -q ':3000'; then
        echo "Erro: Grafana não está ouvindo na porta 3000. Tentando corrigir..."

        # Verificar se o Grafana está ativo
        if ! systemctl is-active --quiet grafana-server; then
            echo "Grafana não está em execução. Iniciando o serviço..."
            systemctl start grafana-server || error_message "Falha ao iniciar o serviço do Grafana"
        fi
        
        # Verificar configuração do arquivo grafana.ini
        if ! grep -q '^http_port\s*=\s*3000' /etc/grafana/grafana.ini; then
            echo "Configurando o Grafana para ouvir na porta 3000..."
            sed -i 's/^#http_port\s*=\s*3000/http_port = 3000/' /etc/grafana/grafana.ini || error_message "Falha ao alterar a configuração do Grafana"
            systemctl restart grafana-server || error_message "Falha ao reiniciar o serviço do Grafana"
        fi

        # Verificar novamente a porta
        if ! ss -tuln | grep -q ':3000'; then
            # Verificar logs do Grafana para diagnóstico
            echo "Grafana ainda não está ouvindo na porta 3000. Verificando logs para diagnóstico..."
            journalctl -u grafana-server -n 20 || error_message "Falha ao recuperar os logs do Grafana"
            
            error_message "Grafana ainda não está ouvindo na porta 3000 após a correção."
        fi
    else
        echo "Grafana já está ouvindo na porta 3000."
    fi
}

# Função para verificar configurações do firewall
check_firewall() {
    echo "Verificando configurações do firewall..."
    if ufw status | grep -q "3000"; then
        echo "A porta 3000 já está permitida no firewall."
    else
        echo "Permitindo a porta 3000 no firewall..."
        ufw allow 3000/tcp || error_message "Falha ao permitir a porta 3000 no firewall"
    fi
}

# Função para remover instalações anteriores
remove_existing() {
    echo "Removendo instalações anteriores..."
    # Remover banco de dados e usuários Zabbix, se existirem
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS $DB_NAME;" || error_message "Erro ao remover o banco de dados"
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP USER IF EXISTS '$DB_USER'@'localhost';" || error_message "Erro ao remover o usuário"
    
    # Remover pacotes do Zabbix e Grafana, se instalados
    apt-get remove --purge -y zabbix-server-mysql zabbix-frontend-php zabbix-agent grafana apache2 || error_message "Erro ao remover pacotes antigos"
    apt-get autoremove -y || error_message "Erro ao remover pacotes não utilizados"
    apt-get clean || error_message "Erro ao limpar pacotes antigos"
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
remove_existing || error_message "Falha ao remover instalações anteriores"

# Configurar timezone e locale
loading_message "Configurando timezone e locale" 3
timedatectl set-timezone "America/Sao_Paulo" || error_message "Falha ao configurar o timezone"
locale-gen "pt_BR.UTF-8" > /dev/null 2>&1 || error_message "Falha ao gerar locale"
update-locale LANG="pt_BR.UTF-8" > /dev/null 2>&1 || error_message "Falha ao atualizar locale"

# Instalar pacotes necessários
loading_message "Atualizando o sistema e instalando pacotes" 3
apt update -y > /dev/null 2>&1 || error_message "Falha ao atualizar pacotes"
apt install -y wget gnupg2 software-properties-common mysql-server nano ufw > /dev/null 2>&1 || error_message "Falha ao instalar pacotes necessários"

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
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_NAME" 2>/dev/null || error_message "Erro ao importar o esquema do banco de dados"

# Configurar Zabbix Server
loading_message "Configurando Zabbix Server" 3
sed -i "s/^# DBPassword=.*/DBPassword=$ZABBIX_USER_PASSWORD/" /etc/zabbix/zabbix_server.conf || error_message "Erro ao configurar o Zabbix"

# Instalar Grafana
loading_message "Instalando Grafana" 3
wget -q -O - https://packages.grafana.com/gpg.key | apt-key add - > /dev/null 2>&1
add-apt-repository "deb https://packages.grafana.com/oss/deb stable main" > /dev/null 2>&1
apt update -y > /dev/null 2>&1
apt install -y grafana > /dev/null 2>&1 || error_message "Erro ao instalar o Grafana"

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

# Verificar se Grafana está ouvindo na porta 3000
check_grafana_port

# Verificar status do firewall e permitir a porta 3000, se necessário
check_firewall

# Finalizar instalação
loading_message "Finalizando instalação do Zabbix e Grafana" 3
systemctl enable zabbix-server zabbix-agent grafana-server apache2 || error_message "Erro ao habilitar serviços"

# Mensagem final com logo do Zabbix
clear
echo "Instalação do Zabbix e Grafana concluída com sucesso!"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Acesse o Zabbix na URL: http://$SERVER_IP/zabbix"
echo "Acesse o Grafana na URL: http://$SERVER_IP:3000"
echo "Senha do usuário Zabbix para o banco de dados: $ZABBIX_USER_PASSWORD"
