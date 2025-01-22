#!/bin/bash

# ===========================
# Instalação Automática: Zabbix + Grafana Enterprise
# ===========================

LOG_FILE="/var/log/zabbix_grafana_install.log"
exec > >(tee -i $LOG_FILE) 2>&1

# Funções Auxiliares
GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

ZABBIX_DB_PASSWORD="zabbix_password"
MYSQL_ROOT_PASSWORD="root_password"

function info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Função para verificar o sucesso de um comando
function check_command() {
    if [ $? -ne 0 ]; then
        error "$1"
    fi
}

# Função para tratar falhas no comando de instalação
function handle_install_error() {
    ERROR_MSG=$1
    PACKAGE_NAME=$2
    if [ -z "$PACKAGE_NAME" ]; then
        PACKAGE_NAME="pacote"
    fi

    error "$ERROR_MSG. Verifique se o pacote $PACKAGE_NAME está disponível nos repositórios ou se a URL de download está correta."
}

# Verificar conectividade com a internet
function check_internet() {
    info "Verificando conexão com a internet..."
    wget -q --spider http://google.com
    if [ $? -ne 0 ]; then
        handle_install_error "Conexão com a internet não detectada" "pacote"
    fi
    info "Conexão com a internet verificada."
}

# Atualização do sistema
function update_system() {
    info "Atualizando sistema..."
    apt-get update -qq > /dev/null
    check_command "Falha ao atualizar os repositórios"
    apt-get upgrade -y -qq > /dev/null
    check_command "Falha ao atualizar os pacotes"
    info "Sistema atualizado com sucesso."
}

# Instalação de ferramentas adicionais e serviços de rede
function install_network_tools() {
    info "Instalando ferramentas de rede e utilitários adicionais..."
    apt-get install -y -qq snmp snmpd nano net-tools curl wget traceroute iputils-ping > /dev/null
    check_command "Falha ao instalar pacotes de rede"
    info "Ferramentas de rede instaladas com sucesso."
}

# Instalação e configuração do MySQL (MariaDB)
function configure_mysql() {
    info "Instalando e configurando MySQL..."
    apt-get install -y -qq mariadb-server > /dev/null
    check_command "Falha ao instalar o MariaDB"

    systemctl start mariadb > /dev/null
    check_command "Falha ao iniciar o serviço MariaDB"
    systemctl enable mariadb > /dev/null
    check_command "Falha ao habilitar o serviço MariaDB"

    mysql -uroot <<EOF > /dev/null
DELETE FROM mysql.user WHERE User='';
FLUSH PRIVILEGES;
CREATE DATABASE zabbix DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_bin;
CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '$ZABBIX_DB_PASSWORD';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;
EOF
    check_command "Falha ao configurar o banco de dados MySQL"
    info "Banco de dados configurado com sucesso."
}

# Instalação do Grafana Enterprise (Versão 9.5.3)
function install_grafana_enterprise() {
    info "Instalando Grafana Enterprise 9.5.3..."

    # Baixar o pacote Grafana Enterprise
    wget https://dl.grafana.com/enterprise/release/grafana-enterprise_9.5.3_amd64.deb -O /tmp/grafana-enterprise.deb
    check_command "Falha ao baixar o pacote do Grafana Enterprise"

    # Instalar o pacote Grafana Enterprise
    dpkg -i /tmp/grafana-enterprise.deb > /dev/null
    check_command "Falha ao instalar o Grafana Enterprise"

    # Resolver dependências, se necessário
    apt-get install -f -y -qq > /dev/null
    check_command "Falha ao resolver dependências do Grafana"

    # Verificar se o Grafana foi instalado corretamente
    dpkg -l | grep grafana > /dev/null
    if [ $? -ne 0 ]; then
        info "Grafana não instalado corretamente. Tentando forçar a instalação novamente..."
        force_grafana_install
    fi

    # Iniciar e habilitar o Grafana
    systemctl enable grafana-server > /dev/null
    systemctl start grafana-server > /dev/null
    check_command "Falha ao iniciar o serviço Grafana"

    # Instalar o plugin Zabbix no Grafana
    grafana-cli plugins install alexanderzobnin-zabbix-app > /dev/null
    check_command "Falha ao instalar o plugin Zabbix no Grafana"
    systemctl restart grafana-server > /dev/null
    check_command "Falha ao reiniciar o Grafana"
    info "Grafana Enterprise instalado com sucesso e plugin Zabbix configurado."
}

# Função para forçar a instalação do Grafana
function force_grafana_install() {
    # Tentar reinstalar o Grafana, se necessário
    apt-get remove --purge -y grafana > /dev/null
    apt-get install -y grafana > /dev/null
    check_command "Falha ao forçar a instalação do Grafana"
    info "Grafana instalado com sucesso após tentativa de contorno."
}

# Remover pacotes antigos
function remove_old_packages() {
    info "Removendo pacotes antigos, se existirem..."

    # Verificar se o pacote Grafana está instalado
    dpkg -l | grep grafana > /dev/null
    if [ $? -eq 0 ]; then
        info "Pacote Grafana encontrado, removendo..."
        apt-get remove -y grafana > /dev/null
        check_command "Falha ao remover o pacote Grafana"
    fi

    # Verificar se o pacote Zabbix está instalado
    dpkg -l | grep zabbix > /dev/null
    if [ $? -eq 0 ]; then
        info "Pacote Zabbix encontrado, removendo..."
        apt-get remove -y zabbix-server zabbix-agent > /dev/null
        check_command "Falha ao remover o pacote Zabbix"
    fi

    # Verificar se o MySQL (MariaDB) está instalado
    dpkg -l | grep mariadb > /dev/null
    if [ $? -eq 0 ]; then
        info "Pacote MariaDB encontrado, removendo..."
        apt-get remove -y mariadb-server > /dev/null
        check_command "Falha ao remover o pacote MariaDB"
    fi
}

# Exibir informações finais de instalação
function display_final_info() {
    info "Instalação concluída com sucesso!"
    info "============================="
    info "Acesse o Zabbix através do navegador em: http://$(hostname -I | awk '{print $1}')/zabbix"
    info "Usuário: Admin"
    info "Senha: zabbix"
    info "============================="
    info "Acesse o Grafana através do navegador em: http://$(hostname -I | awk '{print $1}'):3000"
    info "Usuário: admin"
    info "Senha: admin"
    info "============================="
    info "Versões dos Sistemas Instalados:"
    info "Ubuntu $(lsb_release -rs)"
    info "Zabbix $(zabbix_server -V | head -n 1)"
    info "Grafana $(grafana-cli -v | head -n 1)"
    info "MariaDB $(mysql --version)"
}

# Execução Principal
info "Iniciando instalação..."

check_internet
update_system
remove_old_packages
configure_mysql
install_network_tools
install_grafana_enterprise

# Exibir informações finais após a instalação
display_final_info
