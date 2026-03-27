#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERRO] Falha na linha ${LINENO}. Saindo." >&2; exit 1' ERR

# ====================== Variaveis ======================
readonly ZABBIX_VERSION="7.0"
readonly UBUNTU_CODENAME="noble"
readonly UBUNTU_RELEASE="ubuntu24.04"
readonly GRAFANA_REPO="https://apt.grafana.com"

readonly GRAFANA_APP_PLUGIN="alexanderzobnin-zabbix-app"
readonly GRAFANA_EXTRA_PLUGIN="marcusolsson-dynamictext-panel"

readonly GRAFANA_PORT="3000"
readonly GRAFANA_ADMIN_USER="admin"
readonly GRAFANA_API="http://localhost:${GRAFANA_PORT}/api"
readonly ZABBIX_API_URL="http://localhost/zabbix/api_jsonrpc.php"
readonly ZABBIX_WEB_USER="Admin"
readonly LOG_FILE="/var/log/zabbix_grafana_install.log"

GRAFANA_ADMIN_PASS=""
ZABBIX_WEB_PASS=""

declare -g REINSTALL=false
declare -g NON_INTERACTIVE=false
declare -g DB_USER=""
declare -g DB_PASS=""

# ====================== Logs ======================
log()    { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info()   { echo "[INFO]  $*" | tee -a "$LOG_FILE"; }
warn()   { echo "[AVISO] $*" | tee -a "$LOG_FILE"; }
error()  { echo "[ERRO]  $*" | tee -a "$LOG_FILE" >&2; }

# ====================== Utils ======================
generate_default_passwords() {
    [[ -z "$GRAFANA_ADMIN_PASS" ]] && GRAFANA_ADMIN_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)"
    [[ -z "$ZABBIX_WEB_PASS" ]] && ZABBIX_WEB_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)"
}

# ====================== Sistema ======================
update_system() {
    export NEEDRESTART_MODE=a
    export NEEDRESTART_SUSPEND=1

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    apt-get install -y -qq curl wget jq gnupg2 ca-certificates ufw
}

# ====================== MariaDB ======================
install_mariadb() {
    apt-get install -y -qq mariadb-server
    systemctl enable --now mariadb
}

create_zabbix_db() {
    mysql -uroot <<SQL
DROP DATABASE IF EXISTS zabbix;
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON zabbix.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

# ====================== Zabbix ======================
install_zabbix() {
    wget -q https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.0-1+ubuntu24.04_all.deb
    dpkg -i zabbix-release_7.0-1+ubuntu24.04_all.deb
    apt-get update -qq

    apt-get install -y -qq \
        zabbix-server-mysql zabbix-frontend-php \
        zabbix-apache-conf zabbix-sql-scripts zabbix-agent2 apache2
}

import_schema() {
    zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | \
    mysql -u"$DB_USER" -p"$DB_PASS" zabbix
}

configure_zabbix() {
    sed -i "s|^# DBPassword=.*|DBPassword=${DB_PASS}|" /etc/zabbix/zabbix_server.conf
}

# ====================== Grafana ======================
install_grafana() {
    mkdir -p /etc/apt/keyrings
    wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg

    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
        > /etc/apt/sources.list.d/grafana.list

    apt-get update -qq
    apt-get install -y -qq grafana

    systemctl enable grafana-server
}

install_plugins() {
    grafana-cli plugins install alexanderzobnin-zabbix-app
    grafana-cli plugins install marcusolsson-dynamictext-panel
}

# ====================== 🔧 CORREÇÃO AQUI ======================
configure_grafana_admin_password() {
    local retries=20
    local ok=false

    info "Aguardando Grafana inicializar..."

    while [[ $retries -gt 0 ]]; do
        if curl -sf "http://localhost:${GRAFANA_PORT}/login" > /dev/null 2>&1; then
            ok=true
            break
        fi
        ((retries--))
        sleep 3
    done

    if [[ "$ok" == false ]]; then
        warn "Grafana nao respondeu. Pulando alteracao de senha."
        return
    fi

    sleep 5

    if ! curl -s -X PUT \
        -H "Content-Type: application/json" \
        -u "admin:admin" \
        -d "{\"password\":\"${GRAFANA_ADMIN_PASS}\"}" \
        "http://localhost:${GRAFANA_PORT}/api/user/password" > /dev/null 2>&1; then

        warn "Falha ao alterar senha do Grafana (pode ja estar definida)."
    else
        info "Senha do Grafana configurada."
    fi
}

# ====================== Servicos ======================
start_services() {
    systemctl restart zabbix-server zabbix-agent2 apache2 grafana-server
}

# ====================== Main ======================
main() {
    generate_default_passwords

    read -rp "Usuario DB: " DB_USER
    read -rsp "Senha DB: " DB_PASS; echo

    update_system
    install_mariadb
    create_zabbix_db
    install_zabbix
    import_schema
    configure_zabbix
    install_grafana
    install_plugins

    start_services
    configure_grafana_admin_password

    echo "----------------------------------------"
    echo "Zabbix: http://localhost/zabbix"
    echo "Grafana: http://localhost:3000"
    echo "User: admin"
    echo "Senha Grafana: $GRAFANA_ADMIN_PASS"
    echo "----------------------------------------"
}

main "$@"
