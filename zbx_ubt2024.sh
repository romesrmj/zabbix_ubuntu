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
    apt-get update -qq || error "Falha ao atualizar os repositórios."
    apt-get upgrade -y -qq || error "Falha ao atualizar os pacotes."
    info "Sistema atualizado com sucesso."
}

# Instalação de ferramentas adicionais e serviços de rede
function install_network_tools() {
    info "Instalando ferramentas de rede e utilitários adicionais..."
    apt-get install -y -qq snmp snmpd nano net-tools curl wget traceroute iputils-ping || error "Falha ao instalar pacotes de rede."
    info "Ferramentas de rede instaladas com sucesso."
}

# Solicitação das credenciais para o banco de dados Zabbix
function ask_database_credentials() {
    echo
    read -p "Informe o nome do banco de dados para o Zabbix: " ZABBIX_DB
    read -p "Informe o nome do usuário do banco: " ZABBIX_USER
    read -s -p "Informe a senha do usuário do banco: " ZABBIX_PASS
    echo
}

# Instalação do MySQL
function configure_mysql() {
    info "Instalando e configurando MySQL (MariaDB)..."
    apt-get install -y -qq mariadb-server || error "Falha ao instalar o MariaDB."

    systemctl start mariadb || error "Falha ao iniciar o serviço MariaDB."
    systemctl enable mariadb || error "Falha ao habilitar o serviço MariaDB."

    # Remove banco e usuário caso existam
    mysql -uroot <<EOF || error "Falha ao configurar o banco de dados MySQL."
DROP DATABASE IF EXISTS $ZABBIX_DB;
DROP USER IF EXISTS '$ZABBIX_USER'@'localhost';
FLUSH PRIVILEGES;
CREATE DATABASE $ZABBIX_DB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER '$ZABBIX_USER'@'localhost' IDENTIFIED BY '$ZABBIX_PASS';
GRANT ALL PRIVILEGES ON $ZABBIX_DB.* TO '$ZABBIX_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    info "Banco de dados configurado com sucesso."
}

# Instalação do Zabbix
function install_zabbix() {
    info "Instalando Zabbix..."
    wget -q https://repo.zabbix.com/zabbix/6.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.0-4+ubuntu24.04_all.deb -O zabbix-release.deb || error "Falha ao baixar o repositório do Zabbix."
    dpkg -i zabbix-release.deb || error "Falha ao instalar o pacote de repositório do Zabbix."

    apt-get update -qq
    apt-get install -y -qq zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent || error "Falha ao instalar Zabbix."

    zcat /usr/share/doc/zabbix-server-mysql/create.sql.gz | mysql -u"$ZABBIX_USER" -p"$ZABBIX_PASS" "$ZABBIX_DB" || error "Falha ao importar o esquema do banco."

    sed -i "s/# DBPassword=/DBPassword=$ZABBIX_PASS/" /etc/zabbix/zabbix_server.conf

    systemctl restart zabbix-server zabbix-agent apache2
    systemctl enable zabbix-server zabbix-agent apache2 || error "Falha ao habilitar serviços do Zabbix."
    info "Zabbix instalado com sucesso."
}

# Instalação do Grafana
function install_grafana() {
    info "Instalando Grafana..."
    wget -q https://dl.grafana.com/enterprise/release/grafana-enterprise_8.5.9_amd64.deb -O grafana-enterprise.deb || error "Falha ao baixar o pacote Grafana."
    dpkg -i grafana-enterprise.deb || error "Falha ao instalar o pacote Grafana."

    apt-get update -qq
    apt-get install -y -qq grafana-enterprise || error "Falha ao instalar Grafana."

    systemctl enable grafana-server
    systemctl start grafana-server || error "Falha ao iniciar Grafana."

    grafana-cli plugins install alexanderzobnin-zabbix-app || error "Falha ao instalar o plugin Zabbix no Grafana."
    grafana-cli plugins update-all || error "Falha ao atualizar os plugins do Grafana."

    info "Ativando plugin Zabbix no Grafana..."
    mkdir -p /etc/grafana/provisioning/plugins
    cat <<EOF >/etc/grafana/provisioning/plugins/zabbix.yaml
plugins:
  - name: alexanderzobnin-zabbix-app
    enabled: true
EOF

    info "Configurando fonte de dados Zabbix no Grafana..."
    mkdir -p /etc/grafana/provisioning/datasources
    cat <<EOF >/etc/grafana/provisioning/datasources/zabbix.yaml
apiVersion: 1
datasources:
  - name: Zabbix
    type: alexanderzobnin-zabbix-datasource
    access: proxy
    url: http://localhost/zabbix
    isDefault: true
    jsonData:
      username: Admin
      trends: true
      trendsFrom: "7d"
      cacheTTL: "1h"
    secureJsonData:
      password: zabbix
EOF

    systemctl restart grafana-server || error "Falha ao reiniciar Grafana."
    info "Grafana instalado e plugin Zabbix configurado."
}

# ==== Execução Principal ====
info "Iniciando instalação..."

check_internet
configure_timezone
update_system
install_network_tools
ask_database_credentials
configure_mysql
install_zabbix
install_grafana

info "Instalação concluída com sucesso!"
