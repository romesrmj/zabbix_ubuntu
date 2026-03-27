#!/usr/bin/env bash
# ==============================================================================
#  install_zabbix_grafana.sh
#  Instalação automatizada: Zabbix 7.0 + Grafana OSS + MariaDB
#  Ubuntu 24.04 LTS (Noble Numbat)
#
#  Inclui configuração automática do plugin e datasource Zabbix no Grafana.
#
#  Uso:
#    sudo bash install_zabbix_grafana.sh              # interativo
#    sudo bash install_zabbix_grafana.sh --non-interactive \
#         --db-user zabbix --db-pass 'MinhaS3nh@!'   # pipeline / CI
#
#  GitHub: https://github.com/<seu-usuario>/<seu-repo>
# ==============================================================================

set -Eeuo pipefail
trap 'echo "[ERRO] Falha na linha ${LINENO}. Saindo." >&2; exit 1' ERR

# ==============================================================================
# Variáveis de versão — edite aqui para atualizar
# ==============================================================================
readonly ZABBIX_VERSION="7.0"
readonly UBUNTU_CODENAME="noble"
readonly UBUNTU_RELEASE="ubuntu24.04"
readonly GRAFANA_REPO="https://apt.grafana.com"
readonly GRAFANA_PLUGIN="alexanderzobnin-zabbix-app"
readonly GRAFANA_PORT="3000"
readonly GRAFANA_ADMIN_USER="admin"
readonly GRAFANA_ADMIN_PASS="admin"
readonly GRAFANA_API="http://localhost:${GRAFANA_PORT}/api"
readonly ZABBIX_API_URL="http://localhost/zabbix/api_jsonrpc.php"
readonly ZABBIX_WEB_USER="Admin"
readonly ZABBIX_WEB_PASS="zabbix"
readonly LOG_FILE="/var/log/zabbix_grafana_install.log"

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

# Faz requisição curl com retry (3x) e retorna o body
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

# ==============================================================================
# Verificações de pré-requisito
# ==============================================================================
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "Execute como root: sudo $0 $*"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Nao foi possivel detectar o sistema operacional."
        exit 1
    fi
    # Leitura direta via grep para evitar conflito com variaveis readonly do script
    # (o /etc/os-release do Ubuntu 24.04 exporta UBUNTU_CODENAME=noble, que colidiria)
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

# ==============================================================================
# Parsing de argumentos (suporte a modo não-interativo)
# ==============================================================================
NON_INTERACTIVE=false
DB_USER=""
DB_PASS=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive) NON_INTERACTIVE=true ;;
            --db-user)         DB_USER="$2"; shift ;;
            --db-pass)         DB_PASS="$2"; shift ;;
            --help|-h)
                echo "Uso: sudo $0 [--non-interactive --db-user USER --db-pass PASS]"
                exit 0 ;;
            *) error "Argumento desconhecido: $1"; exit 1 ;;
        esac
        shift
    done
}

# ==============================================================================
# Coleta interativa de credenciais
# ==============================================================================
collect_credentials() {
    if [[ "$NON_INTERACTIVE" == true ]]; then
        [[ -z "$DB_USER" ]] && { error "--db-user e obrigatorio no modo nao-interativo."; exit 1; }
        [[ -z "$DB_PASS" ]] && { error "--db-pass e obrigatorio no modo nao-interativo."; exit 1; }
        return
    fi

    header "Configuracao do banco de dados"

    while true; do
        read -rp "  Nome do usuario do banco (ex: zabbix): " DB_USER
        if [[ -n "$DB_USER" && ! "$DB_USER" =~ [[:space:]] ]]; then
            break
        fi
        warn "Nome de usuario invalido. Sem espacos, nao pode ser vazio."
    done

    while true; do
        read -rsp "  Senha do banco: " DB_PASS; echo
        read -rsp "  Confirme a senha: " DB_PASS2; echo
        if [[ "$DB_PASS" == "$DB_PASS2" && -n "$DB_PASS" ]]; then
            break
        fi
        warn "Senhas nao coincidem ou estao vazias."
    done

    echo
    read -rp "  Confirmar configuracoes e iniciar instalacao? (s/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[sS]$ ]] || { info "Instalacao cancelada."; exit 0; }
}

# ==============================================================================
# Sistema e dependencias
# ==============================================================================
update_system() {
    header "Atualizando sistema"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    apt-get --fix-broken install -y -qq
    dpkg --configure -a
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        snmp snmp-mibs-downloader curl wget gnupg2 jq \
        software-properties-common lsb-release ca-certificates \
        apt-transport-https ufw
    sed -i 's/^mibs :/# mibs :/' /etc/snmp/snmp.conf 2>/dev/null || true
    info "Sistema atualizado."
}

# ==============================================================================
# MariaDB
# ==============================================================================
install_mariadb() {
    header "Instalando e configurando MariaDB"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mariadb-server
    systemctl enable --now mariadb

    mysql -uroot <<'SQL'
        DELETE FROM mysql.user WHERE User='';
        DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
        DROP DATABASE IF EXISTS test;
        DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
        FLUSH PRIVILEGES;
SQL
    info "MariaDB instalado e endurecido."
}

create_zabbix_db() {
    header "Criando banco de dados Zabbix"
    local db_exists
    db_exists=$(mysql -uroot -sse \
        "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='zabbix';")

    if [[ "$db_exists" -eq 1 && "$REINSTALL" == false ]]; then
        warn "Banco 'zabbix' ja existe. Pulando criacao e importacao do schema."
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

    info "Importando schema do Zabbix (pode levar 1-2 minutos)..."
    zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz \
        | mysql --default-character-set=utf8mb4 -u"${DB_USER}" -p"${DB_PASS}" zabbix

    mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;"
    info "Banco de dados criado e schema importado."
}

# ==============================================================================
# Repositorio e pacotes Zabbix
# ==============================================================================
install_zabbix_repo() {
    header "Configurando repositorio Zabbix ${ZABBIX_VERSION}"
    local pkg="zabbix-release_latest_${ZABBIX_VERSION}+${UBUNTU_RELEASE}_all.deb"
    local url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/${UBUNTU_CODENAME}/pool/main/z/zabbix-release/${pkg}"

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

    if grep -q "^#*DBPassword=" "$conf"; then
        sed -i "s|^#*DBPassword=.*|DBPassword=${DB_PASS}|" "$conf"
    else
        echo "DBPassword=${DB_PASS}" >> "$conf"
    fi

    if grep -q "^#*DBUser=" "$conf"; then
        sed -i "s|^#*DBUser=.*|DBUser=${DB_USER}|" "$conf"
    else
        echo "DBUser=${DB_USER}" >> "$conf"
    fi

    chown root:zabbix "$conf"
    chmod 640 "$conf"
    info "Zabbix Server configurado e permissoes restringidas."
}

# ==============================================================================
# Grafana — instalacao
# ==============================================================================
install_grafana() {
    header "Instalando Grafana OSS"
    install -m 0755 -d /usr/share/keyrings
    wget -q -O /usr/share/keyrings/grafana.gpg "${GRAFANA_REPO}/gpg.key"
    echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] ${GRAFANA_REPO} stable main" \
        > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq grafana
    systemctl enable grafana-server
    info "Grafana instalado."
}

# ==============================================================================
# Grafana — plugin Zabbix via CLI
# Instalado ANTES do primeiro start para evitar restart extra.
# ==============================================================================
install_grafana_plugin() {
    header "Instalando plugin Zabbix para Grafana"
    grafana-cli plugins install "$GRAFANA_PLUGIN"
    info "Plugin ${GRAFANA_PLUGIN} instalado."
}

# ==============================================================================
# Grafana — provisionamento via arquivo YAML
#
# Estrategia em duas camadas:
#   1. Arquivo YAML em /etc/grafana/provisioning/ — persiste entre reinicializacoes,
#      nao depende da API e e o metodo recomendado para IaC/GitOps.
#   2. Verificacao + health-check via API REST apos o start — confirma que tudo
#      foi carregado corretamente e testa a conectividade com o Zabbix.
# ==============================================================================
provision_grafana_datasource() {
    header "Provisionando datasource Zabbix via arquivo YAML"

    local ds_dir="/etc/grafana/provisioning/datasources"
    local plugins_dir="/etc/grafana/provisioning/plugins"

    mkdir -p "$ds_dir" "$plugins_dir"

    # ── Datasource ──────────────────────────────────────────────────────────
    cat > "${ds_dir}/zabbix.yaml" <<YAML
# Provisionado automaticamente por install_zabbix_grafana.sh
# Remova este arquivo somente se quiser gerenciar o datasource manualmente.
apiVersion: 1

datasources:
  - name: Zabbix
    type: ${GRAFANA_PLUGIN}
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

    # ── Ativacao do plugin via provisioning ─────────────────────────────────
    # Garante que o plugin aparece como "Enabled" na aba Plugins da UI.
    cat > "${plugins_dir}/zabbix.yaml" <<YAML
# Provisionado automaticamente por install_zabbix_grafana.sh
apiVersion: 1

apps:
  - type: ${GRAFANA_PLUGIN}
    disabled: false
YAML

    # Restringe leitura — arquivos contem credenciais
    chown root:grafana "${ds_dir}/zabbix.yaml" "${plugins_dir}/zabbix.yaml"
    chmod 640 "${ds_dir}/zabbix.yaml" "${plugins_dir}/zabbix.yaml"

    info "Arquivos de provisionamento criados."
}

# ==============================================================================
# Grafana — verificacao pos-start via API REST
# ==============================================================================
configure_grafana_via_api() {
    header "Verificando configuracao do Grafana via API"

    # Aguarda API responder (ate 60 s)
    info "Aguardando API do Grafana..."
    local retries=0
    until curl -sf -o /dev/null \
            -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASS}" \
            "${GRAFANA_API}/health" 2>/dev/null; do
        if [[ $retries -ge 20 ]]; then
            error "Grafana API nao respondeu em 60 segundos."
            journalctl -u grafana-server -n 30 --no-pager >> "$LOG_FILE" 2>&1
            exit 1
        fi
        sleep 3
        ((retries++))
    done
    info "API do Grafana respondendo."

    # ── 1. Verifica datasource provisionado ─────────────────────────────────
    local ds_response
    ds_response=$(grafana_api GET "/datasources/name/Zabbix") || {
        error "Datasource 'Zabbix' nao encontrado via API. Verifique ${LOG_FILE}."
        exit 1
    }

    local ds_id
    ds_id=$(echo "$ds_response" | jq -r '.id // empty')
    if [[ -z "$ds_id" ]]; then
        error "Falha ao obter ID do datasource Zabbix."
        exit 1
    fi
    info "Datasource Zabbix registrado com sucesso (ID: ${ds_id})."

    # ── 2. Health-check do datasource ───────────────────────────────────────
    # O Zabbix Web precisa estar no ar para retornar OK.
    # Aguardamos ate 60 s para o Apache + PHP inicializarem completamente.
    info "Testando conectividade Grafana <-> Zabbix API..."
    local hc_retries=0
    local hc_ok=false
    until [[ $hc_retries -ge 20 ]]; do
        local hc_status
        hc_status=$(grafana_api GET "/datasources/${ds_id}/health" \
            | jq -r '.status // "ERROR"') || true
        if [[ "$hc_status" == "OK" ]]; then
            hc_ok=true
            break
        fi
        sleep 3
        ((hc_retries++))
    done

    if [[ "$hc_ok" == true ]]; then
        info "Health-check OK - Grafana conectado ao Zabbix com sucesso."
    else
        warn "Health-check nao retornou OK. O Zabbix pode ainda estar inicializando."
        warn "Confirme em: Grafana -> Connections -> Data Sources -> Zabbix -> Save & Test."
    fi

    # ── 3. Verifica se plugin esta ativo ────────────────────────────────────
    local plugin_enabled
    plugin_enabled=$(grafana_api GET "/plugins/${GRAFANA_PLUGIN}/settings" \
        | jq -r '.enabled // false') || plugin_enabled="unknown"

    if [[ "$plugin_enabled" == "true" ]]; then
        info "Plugin ${GRAFANA_PLUGIN}: ativo."
    else
        warn "Plugin ${GRAFANA_PLUGIN} pode nao estar ativo na UI."
        warn "Acesse: Grafana -> Administration -> Plugins -> Zabbix -> Enable."
    fi
}

# ==============================================================================
# Firewall (UFW)
# ==============================================================================
configure_firewall() {
    header "Configurando UFW"
    ufw allow OpenSSH
    ufw allow 80/tcp    comment "Zabbix Web"
    ufw allow 443/tcp   comment "Zabbix Web HTTPS"
    ufw allow 3000/tcp  comment "Grafana"
    ufw allow 10050/tcp comment "Zabbix Agent"
    ufw allow 10051/tcp comment "Zabbix Server traps"
    ufw --force enable
    info "Firewall configurado."
}

# ==============================================================================
# Inicializacao de servicos
# ==============================================================================
start_services() {
    header "Iniciando servicos"
    systemctl restart zabbix-server zabbix-agent2 apache2
    systemctl enable  zabbix-server zabbix-agent2 apache2
    # Restart do Grafana para carregar os arquivos de provisionamento
    systemctl restart grafana-server
    info "Servicos iniciados."
}

# ==============================================================================
# Verificacao pos-instalacao
# ==============================================================================
verify_services() {
    header "Verificacao dos servicos"
    local all_ok=true
    local services=("zabbix-server" "zabbix-agent2" "apache2" "mariadb" "grafana-server")

    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            echo -e "  ${GREEN}[OK]${RESET}   $svc"
        else
            echo -e "  ${RED}[FALHA]${RESET} $svc  (veja: journalctl -u $svc)"
            all_ok=false
        fi
    done

    if [[ "$all_ok" == false ]]; then
        error "Um ou mais servicos nao iniciaram. Revise o log: $LOG_FILE"
        exit 1
    fi
}

# ==============================================================================
# Resumo final
# ==============================================================================
print_summary() {
    local SERVER_IP
    SERVER_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')

    echo -e "\n${CYAN}"
    cat <<'BANNER'
 ███████╗ █████╗ ██████╗ ██████╗ ██╗██╗  ██╗
 ╚══███╔╝██╔══██╗██╔══██╗██╔══██╗██║╚██╗██╔╝
   ███╔╝ ███████║██████╔╝██████╔╝██║ ╚███╔╝
  ███╔╝  ██╔══██║██╔══██╗██╔══██╗██║ ██╔██╗
 ███████╗██║  ██║██████╔╝██████╔╝██║██╔╝ ██╗
 ╚══════╝╚═╝  ╚═╝╚═════╝ ╚═════╝ ╚═╝╚═╝  ╚═╝
BANNER
    echo -e "${RESET}"
    echo -e "${BOLD}Instalacao concluida com sucesso!${RESET}"
    echo
    echo -e "  ${BOLD}Zabbix Web :${RESET}  http://${SERVER_IP}/zabbix"
    echo -e "               Login: Admin / zabbix"
    echo
    echo -e "  ${BOLD}Grafana    :${RESET}  http://${SERVER_IP}:3000"
    echo -e "               Login: admin / admin  ${YELLOW}(troque no primeiro acesso)${RESET}"
    echo -e "               Datasource Zabbix: ${GREEN}provisionado automaticamente${RESET}"
    echo -e "               Plugin Zabbix    : ${GREEN}ativado automaticamente${RESET}"
    echo
    echo -e "  ${BOLD}Log        :${RESET}  $LOG_FILE"
    echo
    echo -e "${YELLOW}Proximos passos:${RESET}"
    echo "  1. Acesse o Zabbix Web e conclua o wizard de configuracao inicial."
    echo "  2. O datasource Zabbix no Grafana ja esta configurado."
    echo "     Confirme em: Connections -> Data Sources -> Zabbix -> Save & Test."
    echo "  3. Importe dashboards prontos em grafana.com/grafana/dashboards"
    echo "     (IDs recomendados para Zabbix: 7362 ou 10672)."
    echo "  4. Configure HTTPS com: sudo apt install certbot python3-certbot-apache"
    echo
}

# ==============================================================================
# Ponto de entrada principal
# ==============================================================================
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    log "=== Inicio da instalacao Zabbix ${ZABBIX_VERSION} + Grafana ==="

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
    install_grafana_plugin          # grafana-cli antes do primeiro start
    provision_grafana_datasource    # YAML persiste entre reinicializacoes
    configure_firewall
    start_services                  # restart com provisionamento ja presente
    verify_services
    configure_grafana_via_api       # verificacao + health-check via API REST
    print_summary

    log "=== Instalacao concluida com sucesso ==="
}

main "$@"
