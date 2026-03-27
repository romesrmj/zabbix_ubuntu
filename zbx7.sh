#!/usr/bin/env bash
# ============================================================================== 
#  install_zabbix_grafana.sh
#  Instalação automatizada: Zabbix 7.0 + Grafana OSS + MariaDB
#  Ubuntu 24.04 LTS
# ============================================================================== 

set -Eeuo pipefail
trap 'echo "[ERRO] Falha na linha ${LINENO}. Saindo." >&2; exit 1' ERR

# ============================================================================== 
# Variáveis de versão
# ============================================================================== 
readonly ZABBIX_VERSION="7.0"
readonly ZABBIX_RELEASE_REV="7.0-2"
readonly UBUNTU_RELEASE="ubuntu24.04"
readonly GRAFANA_REPO="https://apt.grafana.com"
readonly GRAFANA_PLUGINS=(
  "alexanderzobnin-zabbix-app"
  "marcusolsson-dynamictext-panel"
)
readonly GRAFANA_PORT="3000"
readonly GRAFANA_ADMIN_USER="admin"
readonly GRAFANA_ADMIN_PASS="admin"
readonly GRAFANA_API="http://localhost:${GRAFANA_PORT}/api"
readonly ZABBIX_API_URL="http://localhost/zabbix/api_jsonrpc.php"
readonly ZABBIX_WEB_USER="Admin"
readonly ZABBIX_WEB_PASS="zabbix"
readonly LOG_FILE="/var/log/zabbix_grafana_install.log"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info()   { echo -e "${GREEN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[AVISO]${RESET} $*" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[ERRO]${RESET}  $*" | tee -a "$LOG_FILE" >&2; }
header() { echo -e "\n${BOLD}${CYAN}==> $*${RESET}" | tee -a "$LOG_FILE"; }

grafana_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local retries=3

    until [[ $retries -eq 0 ]]; do
        local response
        response=$(curl -sf \
            -X "$method" \
            -H "Content-Type: application/json" \
            -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASS}" \
            ${data:+-d "$data"} \
            "${GRAFANA_API}${endpoint}" 2>>"$LOG_FILE") && echo "$response" && return 0
        ((retries--))
        sleep 2
    done
    return 1
}

check_root() {
    [[ "$EUID" -ne 0 ]] && { error "Execute como root: sudo $0 $*"; exit 1; }
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Nao foi possivel detectar o sistema operacional."
        exit 1
    fi
    local os_id os_version os_pretty
    os_id=$(grep -Po '(?<=^ID=)[^\n]+' /etc/os-release | tr -d '"')
    os_version=$(grep -Po '(?<=^VERSION_ID=)[^\n]+' /etc/os-release | tr -d '"')
    os_pretty=$(grep -Po '(?<=^PRETTY_NAME=)[^\n]+' /etc/os-release | tr -d '"')

    if [[ "$os_id" != "ubuntu" || "$os_version" != "24.04" ]]; then
        warn "Este script foi testado no Ubuntu 24.04. Detectado: ${os_pretty}"
        read -rp "Continuar mesmo assim? (s/n): " ans
        [[ "$ans" =~ ^[sS]$ ]] || { info "Instalacao cancelada."; exit 0; }
    fi
}

check_already_installed() {
    if systemctl is-active --quiet zabbix-server 2>/dev/null; then
        warn "Zabbix Server ja esta em execucao neste sistema."
        read -rp "Reinstalar? Isso vai RECRIAR o banco de dados. (s/n): " ans
        [[ "$ans" =~ ^[sS]$ ]] || { info "Instalacao cancelada."; exit 0; }
        REINSTALL=true
    else
        REINSTALL=false
    fi
}

# ------------------------------------------------------------------------------

NON_INTERACTIVE=false
DB_USER=""
DB_PASS=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive) NON_INTERACTIVE=true ;;
            --db-user) DB_USER="$2"; shift ;;
            --db-pass) DB_PASS="$2"; shift ;;
            --help|-h) echo "Uso: sudo $0 [--non-interactive --db-user USER --db-pass PASS]"; exit 0 ;;
            *) error "Argumento desconhecido: $1"; exit 1 ;;
        esac
        shift
    done
}

collect_credentials() {
    if [[ "$NON_INTERACTIVE" == true ]]; then
        [[ -z "$DB_USER" ]] && { error "--db-user e obrigatorio."; exit 1; }
        [[ -z "$DB_PASS" ]] && { error "--db-pass e obrigatorio."; exit 1; }
        return
    fi
    header "Configuracao do banco de dados"
    while true; do
        read -rp "  Nome do usuario do banco (ex: zabbix): " DB_USER
        [[ -n "$DB_USER" && ! "$DB_USER" =~ [[:space:]] ]] && break
        warn "Nome de usuario invalido."
    done
    while true; do
        read -rsp "  Senha do banco: " DB_PASS; echo
        read -rsp "  Confirme a senha: " DB_PASS2; echo
        [[ "$DB_PASS" == "$DB_PASS2" && -n "$DB_PASS" ]] && break
        warn "Senhas nao coincidem ou estao vazias."
    done
    echo
    read -rp "  Confirmar configuracoes e iniciar instalacao? (s/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[sS]$ ]] || { info "Instalacao cancelada."; exit 0; }
}

update_system() {
    header "Atualizando sistema"
    rm -f /etc/apt/sources.list.d/grafana.list /etc/apt/keyrings/grafana.gpg /usr/share/keyrings/grafana.gpg
    for svc in zabbix-server zabbix-agent zabbix-agent2; do systemctl stop "$svc" 2>/dev/null || true; done
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    apt-get --fix-broken install -y -qq
    dpkg --configure -a
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        snmp snmp-mibs-downloader curl wget gnupg2 jq \
        software-properties-common lsb-release ca-certificates \
        apt-transport-https ufw needrestart
    sed -i 's/^mibs :/# mibs :/' /etc/snmp/snmp.conf 2>/dev/null || true
    if [[ -f /etc/needrestart/needrestart.conf ]]; then
        sed -i "s|^#*\$nrconf{restart}.*|\$nrconf{restart} = 'a';|" /etc/needrestart/needrestart.conf
    fi
    info "Sistema atualizado."
}

install_mariadb() {
    header "Instalando e configurando MariaDB"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mariadb-server
    systemctl enable --now mariadb
    mysql -uroot <<'SQL'
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
SQL
    info "MariaDB instalado e endurecido."
}

create_zabbix_db() {
    header "Criando banco de dados Zabbix"
    local db_exists
    db_exists=$(mysql -uroot -sse "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='zabbix';")
    if [[ "$db_exists" -eq 1 && "$REINSTALL" == false ]]; then
        warn "Banco 'zabbix' ja existe. Pulando criacao."
        return
    fi
    mysql -uroot <<SQL
DROP DATABASE IF EXISTS zabbix;
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON zabbix.* TO '${DB_USER}'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
SQL
    info "Importando schema do Zabbix..."
    zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz \
        | mysql --default-character-set=utf8mb4 -u"${DB_USER}" -p"${DB_PASS}" zabbix
    mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;"
    info "Banco de dados criado e schema importado."
}

install_zabbix_repo() {
    header "Configurando repositorio Zabbix ${ZABBIX_VERSION}"
    local pkg="zabbix-release_${ZABBIX_RELEASE_REV}+${UBUNTU_RELEASE}_all.deb"
    local url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/${pkg}"
    wget -q -O "/tmp/${pkg}" "$url"
    dpkg -i "/tmp/${pkg}"
    rm -f "/tmp/${pkg}"
    apt-get update -qq
    info "Repositorio Zabbix configurado."
}

install_zabbix_packages() {
    header "Instalando pacotes Zabbix"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        zabbix-server-mysql \
        zabbix-frontend-php \
        zabbix-apache-conf \
        zabbix-sql-scripts \
        zabbix-agent2 \
        apache2 \
        zabbix-agent2-plugin-mongodb \
        zabbix-agent2-plugin-mssql \
        zabbix-agent2-plugin-postgresql
    info "Pacotes Zabbix instalados."
}

configure_zabbix_server() {
    header "Configurando Zabbix Server"
    local conf="/etc/zabbix/zabbix_server.conf"
    sed -i "s|^#*DBPassword=.*|DBPassword=${DB_PASS}|" "$conf" 2>/dev/null || echo "DBPassword=${DB_PASS}" >> "$conf"
    sed -i "s|^#*DBUser=.*|DBUser=${DB_USER}|" "$conf" 2>/dev/null || echo "DBUser=${DB_USER}" >> "$conf"
    chown root:zabbix "$conf"
    chmod 640 "$conf"
    info "Zabbix Server configurado."
}

install_grafana() {
    header "Instalando Grafana OSS"
    mkdir -p /etc/apt/keyrings
    wget -q -O - "${GRAFANA_REPO}/gpg.key" | gpg --dearmor | tee /etc/apt/keyrings/grafana.gpg > /dev/null
    chmod 644 /etc/apt/keyrings/grafana.gpg
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] ${GRAFANA_REPO} stable main" > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq grafana
    systemctl enable grafana-server
    info "Grafana OSS instalado."
}

install_grafana_plugin() {
    header "Instalando plugins do Grafana"
    for plugin in "${GRAFANA_PLUGINS[@]}"; do
        info "Instalando plugin: $plugin"
        grafana-cli plugins install "$plugin"
    done
    info "Plugins instalados com sucesso."
}

provision_grafana_datasource() {
    header "Provisionando datasource Zabbix via arquivo YAML"
    local ds_dir="/etc/grafana/provisioning/datasources"
    local plugins_dir="/etc/grafana/provisioning/plugins"
    mkdir -p "$ds_dir" "$plugins_dir"
    local main_plugin="${GRAFANA_PLUGINS[0]}"
    cat > "${ds_dir}/zabbix.yaml" <<YAML
apiVersion: 1
datasources:
  - name: Zabbix
    type: ${main_plugin}
    access: proxy
    url: ${ZABBIX_API_URL}
    isDefault: true
    editable: true
    jsonData:
      authType: userLogin
      username: ${ZABBIX_WEB_USER}
      trends: true
      trendsFrom: "7d"
      trendsRange: "4d"
      cachingTTL: 600
      alerting: true
      addThresholds: true
      alertingMinSeverity: 3
      disableReadOnlyUsersAck: false
      dbConnectionEnable: false
    secureJsonData:
      password: ${ZABBIX_WEB_PASS}
YAML

    cat > "${plugins_dir}/zabbix.yaml" <<YAML
apiVersion: 1
apps:
  - type: ${main_plugin}
    disabled: false
YAML

    chown root:grafana "${ds_dir}/zabbix.yaml" "${plugins_dir}/zabbix.yaml"
    chmod 640 "${ds_dir}/zabbix.yaml" "${plugins_dir}/zabbix.yaml"
    info "Arquivos de provisionamento criados."
}

configure_firewall() {
    header "Configurando UFW"
    ufw allow OpenSSH
    ufw allow 80/tcp comment "Zabbix Web"
    ufw allow 443/tcp comment "Zabbix Web HTTPS"
    ufw allow 3000/tcp comment "Grafana"
    ufw allow 10050/tcp comment "Zabbix Agent"
    ufw allow 10051/tcp comment "Zabbix Server traps"
    ufw --force enable
    info "Firewall configurado."
}

start_services() {
    header "Iniciando servicos"
    systemctl restart zabbix-server zabbix-agent2 apache2
    systemctl enable zabbix-server zabbix-agent2 apache2
    systemctl restart grafana-server
    info "Servicos iniciados."
}

verify_services() {
    header "Verificacao dos servicos"
    local all_ok=true
    local services=("zabbix-server" "zabbix-agent2" "apache2" "mariadb" "grafana-server")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            echo -e "  ${GREEN}[OK]${RESET}   $svc"
        else
            echo -e "  ${RED}[FALHA]${RESET} $svc"
            all_ok=false
        fi
    done
    [[ "$all_ok" == false ]] && { error "Um ou mais servicos nao iniciaram. Veja o log: $LOG_FILE"; exit 1; }
}

configure_grafana_via_api() {
    header "Verificando configuracao do Grafana via API"
    info "Aguardando API do Grafana..."
    local retries=0
    until curl -sf -o /dev/null "${GRAFANA_API}/health" 2>/dev/null; do
        ((retries++))
        [[ $retries -ge 30 ]] && { error "Grafana API nao respondeu"; exit 1; }
        sleep 3
    done
    info "API do Grafana respondendo."
}

main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    log "=== Inicio da instalacao Zabbix + Grafana ==="
    parse_args "$@"
    check_root
    check_os
    check_already_installed
    collect_credentials
    update_system
    install_mariadb
    install_zabbix_repo
    install_zabbix_packages
    create_zabbix_db
    configure_zabbix_server
    install_grafana
    install_grafana_plugin
    provision_grafana_datasource
    configure_firewall
    start_services
    verify_services
    configure_grafana_via_api
    log "=== Instalacao concluida com sucesso ==="
}

main "$@"
