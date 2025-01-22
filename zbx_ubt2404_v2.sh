#!/bin/bash

# ===========================
# Instalação Automática: Zabbix + Grafana
# Compatível com Ubuntu Server 24.04 (Minimal)
# ===========================

LOG_FILE="/var/log/zabbix_grafana_install.log"
exec > >(tee -i $LOG_FILE) 2>&1

# ==== Funções Auxiliares ====
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

# Verificar conectividade com a internet
function check_internet() {
    info "Verificando conexão com a internet..."
    wget -q --spider http://google.com
    if [ $? -ne 0 ]; then
        error "Conexão com a internet não detectada. Verifique sua rede."
    fi
    info "Conexão com a internet verificada."
}

# Configuração do fuso horário
function configure_timezone() {
    info "Configurando fuso horário para America/Sao_Paulo..."
    timedatectl set-timezone America/Sao_Paulo || error "Falha ao configurar o fuso horário."
    info "Fuso horário configurado com sucesso."
}

# Atualização do sistema
function update_system() {
    info "Atualizando sistema..."
    apt-get update -qq > /dev/null || error "Falha ao atualizar os repositórios."
    apt-get upgrade -y -qq > /dev/null || error "Falha ao atualizar os pacotes."
    info "Sistema atualizado com sucesso."
}

# Instalação de ferramentas adicionais e serviços de rede
function install_network_tools() {
    info "Instalando ferramentas de rede e utilitários adicionais..."
    apt-get install -y -qq snmp snmpd nano net-tools curl wget traceroute iputils-ping > /dev/null || error "Falha ao instalar pacotes de rede."
    info "Ferramentas de rede instaladas com sucesso."
}

# Remover pacotes anteriores e limpar ambiente
function clean_previous_installations() {
    info "Verificando e removendo instalações anteriores de Zabbix, Grafana e MySQL..."

    # Parar e desabilitar serviços se existirem
    for service in zabbix-server zabbix-agent grafana-server mariadb apache2; do
        if systemctl is-active --quiet $service; then
            info "Parando serviço: $service..."
            systemctl stop $service > /dev/null || error "Falha ao parar o serviço $service."
        fi

        if systemctl is-enabled --quiet $service; then
            info "Desabilitando serviço: $service..."
            systemctl disable $service > /dev/null || error "Falha ao desabilitar o serviço $service."
        fi
    done

    # Remover pacotes e configurações residuais
    info "Removendo pacotes relacionados..."
    apt-get purge -y -qq zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent grafana-enterprise mariadb-server > /dev/null || error "Falha ao remover pacotes."
    apt-get autoremove -y -qq > /dev/null || error "Falha ao remover dependências desnecessárias."
    apt-get autoclean -qq > /dev/null || error "Falha ao limpar pacotes antigos."

    # Remover arquivos residuais de configuração
    info "Limpando arquivos residuais..."
    rm -rf /etc/zabbix /etc/grafana /var/lib/mysql /var/lib/grafana > /dev/null || error "Falha ao limpar arquivos residuais."

    info "Ambiente limpo com sucesso!"
}

# Instalação e configuração do MySQL (MariaDB)
function configure_mysql() {
    info "Instalando e configurando MySQL..."
    apt-get install -y -qq mariadb-server > /dev/null || error "Falha ao instalar o MariaDB."

    systemctl start mariadb > /dev/null || error "Falha ao iniciar o serviço MariaDB."
    systemctl enable mariadb > /dev/null || error "Falha ao habilitar o serviço MariaDB."

    mysql -uroot <<EOF > /dev/null || error "Falha ao configurar o banco de dados MySQL."
DELETE FROM mysql.user WHERE User='';
FLUSH PRIVILEGES;
CREATE DATABASE zabbix DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_bin;
CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '$ZABBIX_DB_PASSWORD';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;
EOF

    info "Banco de dados configurado com sucesso."
}

# Instalação do Zabbix
function install_zabbix() {
    info "Instalando Zabbix..."
    wget -q https://repo.zabbix.com/zabbix/6.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.0-4+ubuntu24.04_all.deb -O zabbix-release.deb > /dev/null || error "Falha ao baixar o repositório do Zabbix."
    dpkg -i zabbix-release.deb > /dev/null || error "Falha ao instalar o pacote de repositório do Zabbix."

    apt-get update -qq > /dev/null
    apt-get install -y -qq zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent > /dev/null || error "Falha ao instalar Zabbix."

    zcat /usr/share/doc/zabbix-server-mysql/create.sql.gz | mysql -uzabbix -p$ZABBIX_DB_PASSWORD zabbix > /dev/null || error "Falha ao importar o esquema do banco."
    sed -i "s/# DBPassword=/DBPassword=$ZABBIX_DB_PASSWORD/" /etc/zabbix/zabbix_server.conf
    systemctl restart zabbix-server zabbix-agent apache2 > /dev/null
    systemctl enable zabbix-server zabbix-agent apache2 > /dev/null || error "Falha ao habilitar serviços do Zabbix."
    info "Zabbix instalado com sucesso."
}

# Instalação do Grafana
function install_grafana() {
    info "Instalando Grafana..."
    wget -q https://dl.grafana.com/enterprise/release/grafana-enterprise_8.5.9_amd64.deb -O grafana-enterprise.deb > /dev/null || error "Falha ao baixar o pacote Grafana."
    dpkg -i grafana-enterprise.deb > /dev/null || error "Falha ao instalar o pacote Grafana."

    apt-get update -qq > /dev/null
    apt-get install -y -qq grafana-enterprise > /dev/null || error "Falha ao instalar Grafana."

    systemctl enable grafana-server > /dev/null
    systemctl start grafana-server > /dev/null || error "Falha ao iniciar Grafana."

    grafana-cli plugins install alexanderzobnin-zabbix-app > /dev/null || error "Falha ao instalar o plugin Zabbix no Grafana."
    grafana-cli plugins update-all > /dev/null || error "Falha ao atualizar os plugins do Grafana."
    systemctl restart grafana-server > /dev/null || error "Falha ao reiniciar Grafana."
    info "Grafana instalado e plugin Zabbix configurado."
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

# ==== Execução Principal ====
info "Iniciando instalação..."

check_internet
configure_timezone
update_system
install_network_tools
clean_previous_installations
configure_mysql
install_zabbix
install_grafana

# Exibir informações finais após a instalação
display_final_info
