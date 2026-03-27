#!/usr/bin/env bash
# ============================================================================== 
# install_zabbix_grafana.sh - Instala Zabbix 7.0 + Grafana OSS + MariaDB
# Ubuntu 24.04 LTS
# ==============================================================================

set -Eeuo pipefail
trap 'echo "[ERRO] Falha na linha ${LINENO}. Saindo." >&2; exit 1' ERR

# ============================================================================== 
# Variáveis de versão
# ============================================================================== 
readonly ZABBIX_VERSION="7.0"
readonly ZABBIX_RELEASE_REV="7.0-2"
readonly UBUNTU_CODENAME="noble"
readonly UBUNTU_RELEASE="ubuntu24.04"
readonly GRAFANA_REPO="https://apt.grafana.com"
readonly GRAFANA_PORT="3000"
readonly GRAFANA_ADMIN_USER="admin"
readonly GRAFANA_ADMIN_PASS="admin"
readonly GRAFANA_API="http://localhost:${GRAFANA_PORT}/api"
readonly ZABBIX_API_URL="http://localhost/zabbix/api_jsonrpc.php"
readonly ZABBIX_WEB_USER="Admin"
readonly ZABBIX_WEB_PASS="zabbix"
readonly LOG_FILE="/var/log/zabbix_grafana_install.log"

# ===================== CORREÇÃO DE PLUGINS ===================== 
# Define os plugins do Grafana que serão instalados
readonly GRAFANA_PLUGINS=(
  "alexanderzobnin-zabbix-app"
  "marcusolsson-dynamictext-panel"
)

# ============================================================================== 
# Utilitários
# ============================================================================== 
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
        response=$(curl -sf -X "$method" -H "Content-Type: application/json" \
            -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASS}" \
            ${data:+-d "$data"} "${GRAFANA_API}${endpoint}" 2>>"$LOG_FILE") && echo "$response" && return 0
        ((retries--))
        sleep 2
    done
    return 1
}

# ============================================================================== 
# Instalacao do Grafana e plugins
# ============================================================================== 
install_grafana() {
    header "Instalando Grafana OSS"
    mkdir -p /etc/apt/keyrings
    wget -q -O - "${GRAFANA_REPO}/gpg.key" | gpg --dearmor | tee /etc/apt/keyrings/grafana.gpg >/dev/null
    chmod 644 /etc/apt/keyrings/grafana.gpg
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] ${GRAFANA_REPO} stable main" > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq grafana
    systemctl enable grafana-server
    info "Grafana OSS instalado."
}

install_grafana_plugins() {
    header "Instalando plugins do Grafana"
    for plugin in "${GRAFANA_PLUGINS[@]}"; do
        info "Instalando plugin: $plugin"
        grafana-cli plugins install "$plugin"
    done
    info "Plugins instalados com sucesso."
}

provision_grafana_datasource() {
    header "Provisionando datasource Zabbix via YAML"
    local ds_dir="/etc/grafana/provisioning/datasources"
    local plugins_dir="/etc/grafana/provisioning/plugins"
    mkdir -p "$ds_dir" "$plugins_dir"

    cat > "${ds_dir}/zabbix.yaml" <<YAML
apiVersion: 1
datasources:
  - name: Zabbix
    type: alexanderzobnin-zabbix-app
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
  - type: alexanderzobnin-zabbix-app
    disabled: false
YAML

    chown root:grafana "${ds_dir}/zabbix.yaml" "${plugins_dir}/zabbix.yaml"
    chmod 640 "${ds_dir}/zabbix.yaml" "${plugins_dir}/zabbix.yaml"
    info "Arquivos de provisionamento criados."
}

# ============================================================================== 
# Ponto de entrada
# ============================================================================== 
main() {
    apt-get update -qq
    apt-get install -y -qq wget curl gnupg2 jq
    install_grafana
    install_grafana_plugins
    provision_grafana_datasource
    systemctl restart grafana-server
    info "Grafana pronto com datasource e plugins Zabbix instalados."
}

main "$@"
