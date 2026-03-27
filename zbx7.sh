#!/usr/bin/env bash
# ====================================================================
#  install_zabbix_grafana.sh
#  Instalacao automatizada: Zabbix 7.0 + Grafana OSS + MariaDB
#  Ubuntu 24.04 LTS
# ====================================================================

set -Eeuo pipefail
trap 'echo "[ERRO] Falha na linha ${LINENO}. Saindo." >&2; exit 1' ERR

# ====================== Variaveis ======================
readonly ZABBIX_VERSION="7.0"
readonly ZABBIX_RELEASE_REV="7.0-2"
readonly UBUNTU_CODENAME="noble"
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

# ====================== Funcoes de log ======================
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info()   { echo -e "${GREEN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[AVISO]${RESET} $*" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[ERRO]${RESET}  $*" | tee -a "$LOG_FILE" >&2; }
header() { echo -e "\n${BOLD}${CYAN}==> $*${RESET}" | tee -a "$LOG_FILE"; }

# ====================== Grafana API helper ======================
grafana_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local retries=3

    until [[ $retries -eq 0 ]]; do
        local response
        response=$(curl -sf -X "$method" -H "Content-Type: application/json" \
            -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASS}" \
            ${data:+-d "$data"} \
            "${GRAFANA_API}${endpoint}" 2>>"$LOG_FILE") && echo "$response" && return 0
        ((retries--))
        sleep 2
    done
    return 1
}

# ====================== Checagens ======================
check_root() {
    [[ "$EUID" -ne 0 ]] && { error "Execute como root"; exit 1; }
}

check_os() {
    [[ ! -f /etc/os-release ]] && { error "Nao foi possivel detectar o SO"; exit 1; }
}

check_already_installed() {
    if systemctl is-active --quiet zabbix-server 2>/dev/null; then
        warn "Zabbix Server ja esta em execucao."
        read -rp "Reinstalar? (s/n): " ans
        [[ "$ans" =~ ^[sS]$ ]] || exit 0
        REINSTALL=true
    else
        REINSTALL=false
    fi
}

# ====================== Argumentos ======================
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

# ====================== Credenciais ======================
collect_credentials() {
    if [[ "$NON_INTERACTIVE" == true ]]; then
        [[ -z "$DB_USER" ]] && { error "--db-user e obrigatorio"; exit 1; }
        [[ -z "$DB_PASS" ]] && { error "--db-pass e obrigatorio"; exit 1; }
        return
    fi

    header "Configuracao do banco de dados"
    while true; do
        read -rp "  Nome do usuario do banco: " DB_USER
        [[ -n "$DB_USER" && ! "$DB_USER" =~ [[:space:]] ]] && break
        warn "Nome invalido."
    done

    while true; do
        read -rsp "  Senha do banco: " DB_PASS; echo
        read -rsp "  Confirme a senha: " DB_PASS2; echo
        [[ "$DB_PASS" == "$DB_PASS2" && -n "$DB_PASS" ]] && break
        warn "Senhas nao coincidem ou vazias."
    done

    read -rp "Confirmar e iniciar instalacao? (s/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[sS]$ ]] || exit 0
}

# ====================== Sistema ======================
update_system() {
    header "Atualizando sistema"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    apt-get --fix-broken install -y -qq
    dpkg --configure -a
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        snmp snmp-mibs-downloader curl wget gnupg2 jq \
        software-properties-common lsb-release ca-certificates \
        apt-transport-https ufw needrestart
    info "Sistema atualizado."
}

# ====================== MariaDB ======================
install_mariadb() {
    header "Instalando MariaDB"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mariadb-server
    systemctl enable --now mariadb
    mysql -uroot <<'SQL'
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
    info "MariaDB instalado."
}

create_zabbix_db() {
    header "Criando banco Zabbix"
    mysql -uroot <<SQL
DROP DATABASE IF EXISTS zabbix;
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON zabbix.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    info "Banco Zabbix criado."
}

# ====================== Zabbix ======================
install_zabbix_repo() {
    header "Configurando repositorio Zabbix"
    local pkg="zabbix-release_${ZABBIX_RELEASE_REV}+${UBUNTU_RELEASE}_all.deb"
    wget -q -O "/tmp/${pkg}" "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/${pkg}"
    dpkg -i "/tmp/${pkg}"
    rm -f "/tmp/${pkg}"
    apt-get update -qq
    info "Repositorio Zabbix configurado."
}

install_zabbix_packages() {
    header "Instalando pacotes Zabbix"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf \
        zabbix-sql-scripts zabbix-agent2 apache2
    info "Pacotes Zabbix instalados."
}

configure_zabbix_server() {
    header "Configurando Zabbix Server"
    sed -i "s|^#*DBUser=.*|DBUser=${DB_USER}|" /etc/zabbix/zabbix_server.conf
    sed -i "s|^#*DBPassword=.*|DBPassword=${DB_PASS}|" /etc/zabbix/zabbix_server.conf
    chown root:zabbix /etc/zabbix/zabbix_server.conf
    chmod 640 /etc/zabbix/zabbix_server.conf
}

# ====================== Grafana ======================
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
    header "Instalando plugins Grafana"
    for plugin in "${GRAFANA_PLUGINS[@]}"; do
        info "Instalando plugin: $plugin"
        grafana-cli plugins install "$plugin"
    done
}

provision_grafana_datasource() {
    header "Provisionando datasource Zabbix via YAML"
    local ds_dir="/etc/grafana/provisioning/datasources"
    local plugins_dir="/etc/grafana/provisioning/plugins"
    mkdir -p "$ds_dir" "$plugins_dir"

    for plugin in "${GRAFANA_PLUGINS[@]}"; do
        cat > "${ds_dir}/${plugin}.yaml" <<YAML
apiVersion: 1
datasources:
  - name: Zabbix
    type: $plugin
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
        cat > "${plugins_dir}/${plugin}.yaml" <<YAML
apiVersion: 1
apps:
  - type: $plugin
    disabled: false
YAML
        chown root:grafana "${ds_dir}/${plugin}.yaml" "${plugins_dir}/${plugin}.yaml"
        chmod 640 "${ds_dir}/${plugin}.yaml" "${plugins_dir}/${plugin}.yaml"
    done
    info "Arquivos de provisionamento criados."
}

# ====================== Firewall ======================
configure_firewall() {
    header "Configurando UFW"
    ufw allow OpenSSH
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 3000/tcp
    ufw allow 10050/tcp
    ufw allow 10051/tcp
    ufw --force enable
}

# ====================== Servicos ======================
start_services() {
    header "Iniciando servicos"
    systemctl restart zabbix-server zabbix-agent2 apache2 grafana-server
    systemctl enable zabbix-server zabbix-agent2 apache2 grafana-server
}

# ====================== Principal ======================
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
    log "=== Instalacao concluida com sucesso ==="
}

main "$@"
