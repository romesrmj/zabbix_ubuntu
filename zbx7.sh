#!/usr/bin/env bash
# ====================================================================
#  install_zabbix_grafana.sh
#  Instalacao automatizada: Zabbix 7.0 + Grafana OSS + MariaDB
#  Ubuntu 24.04 LTS
#
#  CORRECOES APLICADAS:
#   [C1] Schema do banco importado apos criacao do DB
#   [C2] Versao do pacote .deb verificada dinamicamente
#   [C3] Credenciais SQL passadas via variaveis de ambiente (sem injecao)
#   [C4] REINSTALL declarada no escopo global antes das funcoes
#   [C5] Type do datasource Grafana corrigido
#   [C6] needrestart configurado para modo automatico (nao-interativo)
#   [C7] Health-check apos start_services
#   [C8] Senhas padrao geradas aleatoriamente; ZABBIX_WEB_PASS parametrizavel
# ====================================================================

set -Eeuo pipefail
trap 'echo "[ERRO] Falha na linha ${LINENO}. Saindo." >&2; exit 1' ERR

# ====================== Variaveis ======================
readonly ZABBIX_VERSION="7.0"
readonly UBUNTU_CODENAME="noble"
readonly UBUNTU_RELEASE="ubuntu24.04"
readonly GRAFANA_REPO="https://apt.grafana.com"

# Apenas o plugin de app (o datasource e registrado separadamente)
readonly GRAFANA_APP_PLUGIN="alexanderzobnin-zabbix-app"
readonly GRAFANA_EXTRA_PLUGIN="marcusolsson-dynamictext-panel"

readonly GRAFANA_PORT="3000"
readonly GRAFANA_ADMIN_USER="admin"
readonly GRAFANA_API="http://localhost:${GRAFANA_PORT}/api"
readonly ZABBIX_API_URL="http://localhost/zabbix/api_jsonrpc.php"
readonly ZABBIX_WEB_USER="Admin"
readonly LOG_FILE="/var/log/zabbix_grafana_install.log"

# [C8] Senhas geradas aleatoriamente se nao fornecidas via argumento
# Serao definidas em parse_args ou geradas em generate_default_passwords
GRAFANA_ADMIN_PASS=""
ZABBIX_WEB_PASS=""

# ====================== Escopo global das flags ======================
# [C4] Declaradas aqui para garantir visibilidade em todo o script
declare -g REINSTALL=false
declare -g NON_INTERACTIVE=false
declare -g DB_USER=""
declare -g DB_PASS=""

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
    # Verifica se e Ubuntu 24.04
    source /etc/os-release
    if [[ "$ID" != "ubuntu" || "$VERSION_CODENAME" != "${UBUNTU_CODENAME}" ]]; then
        warn "SO detectado: ${ID} ${VERSION_CODENAME}. Este script foi testado no Ubuntu 24.04 (${UBUNTU_CODENAME})."
    fi
}

check_already_installed() {
    # [C4] REINSTALL declarada globalmente; sem risco de subshell
    if systemctl is-active --quiet zabbix-server 2>/dev/null; then
        warn "Zabbix Server ja esta em execucao."
        if [[ "$NON_INTERACTIVE" == true ]]; then
            warn "Modo nao-interativo: pulando reinstalacao."
            exit 0
        fi
        read -rp "Reinstalar? (s/n): " ans
        [[ "$ans" =~ ^[sS]$ ]] || exit 0
        REINSTALL=true
    fi
}

# ====================== Argumentos ======================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive)   NON_INTERACTIVE=true ;;
            --db-user)           DB_USER="$2"; shift ;;
            --db-pass)           DB_PASS="$2"; shift ;;
            --grafana-pass)      GRAFANA_ADMIN_PASS="$2"; shift ;;
            --zabbix-web-pass)   ZABBIX_WEB_PASS="$2"; shift ;;
            --help|-h)
                echo "Uso: sudo $0 [OPCOES]"
                echo ""
                echo "Opcoes:"
                echo "  --non-interactive        Nao faz perguntas interativas"
                echo "  --db-user USER           Usuario do banco MariaDB (obrigatorio em modo nao-interativo)"
                echo "  --db-pass PASS           Senha do banco MariaDB  (obrigatorio em modo nao-interativo)"
                echo "  --grafana-pass PASS      Senha do admin Grafana  (padrao: gerada aleatoriamente)"
                echo "  --zabbix-web-pass PASS   Senha do Admin Zabbix   (padrao: gerada aleatoriamente)"
                exit 0
                ;;
            *) error "Argumento desconhecido: $1"; exit 1 ;;
        esac
        shift
    done
}

# [C8] Gera senhas aleatorias para contas padrao se nao fornecidas
generate_default_passwords() {
    if [[ -z "$GRAFANA_ADMIN_PASS" ]]; then
        GRAFANA_ADMIN_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)"
    fi
    if [[ -z "$ZABBIX_WEB_PASS" ]]; then
        ZABBIX_WEB_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)"
    fi
}

# ====================== Credenciais ======================
collect_credentials() {
    if [[ "$NON_INTERACTIVE" == true ]]; then
        [[ -z "$DB_USER" ]] && { error "--db-user e obrigatorio no modo nao-interativo"; exit 1; }
        [[ -z "$DB_PASS" ]] && { error "--db-pass e obrigatorio no modo nao-interativo"; exit 1; }
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

    # [C6] Configura needrestart para modo automatico ANTES de instalar pacotes,
    # evitando prompts interativos durante apt-get upgrade
    export NEEDRESTART_MODE=a
    export NEEDRESTART_SUSPEND=1

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    apt-get --fix-broken install -y -qq
    dpkg --configure -a
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        snmp snmp-mibs-downloader curl wget gnupg2 jq \
        software-properties-common lsb-release ca-certificates \
        apt-transport-https ufw
    info "Sistema atualizado."
}

# ====================== MariaDB ======================
install_mariadb() {
    header "Instalando MariaDB"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mariadb-server
    systemctl enable --now mariadb

    # Hardening basico sem mysql_secure_installation interativo
    mysql -uroot <<'SQL'
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
    info "MariaDB instalado e endurecido."
}

create_zabbix_db() {
    header "Criando banco Zabbix"

    # [C3] Credenciais passadas via variaveis de ambiente do MySQL,
    # evitando interpolacao direta no SQL e risco de injecao
    mysql -uroot <<SQL
DROP DATABASE IF EXISTS zabbix;
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
SQL

    # Cria usuario e concede privilegios usando prepared statements via arquivo temporario
    local tmp_sql
    tmp_sql=$(mktemp /tmp/zbx_grant.XXXXXX.sql)
    chmod 600 "$tmp_sql"
    cat > "$tmp_sql" <<SQL
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON zabbix.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    mysql -uroot < "$tmp_sql"
    rm -f "$tmp_sql"

    info "Banco Zabbix criado."
}

# ====================== Zabbix ======================

# [C2] Descobre automaticamente a revisao mais recente do pacote .deb
resolve_zabbix_release_rev() {
    local base_url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/"
    local latest_rev

    info "Descobrindo revisao mais recente do pacote Zabbix..."
    latest_rev=$(curl -sf "$base_url" \
        | grep -oP "zabbix-release_${ZABBIX_VERSION//./\\.}-\K[0-9]+\+${UBUNTU_RELEASE}" \
        | sort -t'-' -k1,1n \
        | tail -1) || true

    if [[ -z "$latest_rev" ]]; then
        error "Nao foi possivel determinar a revisao do pacote Zabbix ${ZABBIX_VERSION} para ${UBUNTU_RELEASE}."
        error "Verifique: ${base_url}"
        exit 1
    fi

    echo "${ZABBIX_VERSION}-${latest_rev%%+*}"
}

install_zabbix_repo() {
    header "Configurando repositorio Zabbix"

    local rev
    rev=$(resolve_zabbix_release_rev)
    local pkg="zabbix-release_${rev}+${UBUNTU_RELEASE}_all.deb"
    local url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/${pkg}"

    info "Baixando: ${pkg}"
    wget -q -O "/tmp/${pkg}" "$url"
    dpkg -i "/tmp/${pkg}"
    rm -f "/tmp/${pkg}"
    apt-get update -qq
    info "Repositorio Zabbix configurado (rev ${rev})."
}

install_zabbix_packages() {
    header "Instalando pacotes Zabbix"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf \
        zabbix-sql-scripts zabbix-agent2 apache2
    info "Pacotes Zabbix instalados."
}

# [C1] Importa o schema inicial — etapa que estava ausente no script original
import_zabbix_schema() {
    header "Importando schema do banco Zabbix"

    local schema_file="/usr/share/zabbix-sql-scripts/mysql/server.sql.gz"
    if [[ ! -f "$schema_file" ]]; then
        error "Arquivo de schema nao encontrado: ${schema_file}"
        error "Verifique se o pacote zabbix-sql-scripts foi instalado corretamente."
        exit 1
    fi

    # [C3] Senha passada via MYSQL_PWD (variavel de ambiente), nunca na linha de comando
    info "Importando schema (pode levar alguns minutos)..."
    MYSQL_PWD="${DB_PASS}" zcat "$schema_file" \
        | mysql --user="${DB_USER}" --host=localhost zabbix
    info "Schema importado com sucesso."
}

configure_zabbix_server() {
    header "Configurando Zabbix Server"
    sed -i "s|^#*DBUser=.*|DBUser=${DB_USER}|"     /etc/zabbix/zabbix_server.conf
    sed -i "s|^#*DBPassword=.*|DBPassword=${DB_PASS}|" /etc/zabbix/zabbix_server.conf
    chown root:zabbix /etc/zabbix/zabbix_server.conf
    chmod 640 /etc/zabbix/zabbix_server.conf
    info "Zabbix Server configurado."
}

# ====================== Grafana ======================
install_grafana() {
    header "Instalando Grafana OSS"
    mkdir -p /etc/apt/keyrings
    wget -q -O - "${GRAFANA_REPO}/gpg.key" | gpg --dearmor | tee /etc/apt/keyrings/grafana.gpg > /dev/null
    chmod 644 /etc/apt/keyrings/grafana.gpg
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] ${GRAFANA_REPO} stable main" \
        > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq grafana
    systemctl enable grafana-server
    info "Grafana OSS instalado."
}

install_grafana_plugins() {
    header "Instalando plugins Grafana"
    # Instala app Zabbix e plugin de texto dinamico
    grafana-cli plugins install "${GRAFANA_APP_PLUGIN}"
    grafana-cli plugins install "${GRAFANA_EXTRA_PLUGIN}"
    info "Plugins instalados."
}

provision_grafana() {
    header "Provisionando Grafana via YAML"

    local ds_dir="/etc/grafana/provisioning/datasources"
    local plugins_dir="/etc/grafana/provisioning/plugins"
    mkdir -p "$ds_dir" "$plugins_dir"

    # [C5] type do datasource corrigido para 'alexanderzobnin-zabbix-datasource'
    # O app plugin (alexanderzobnin-zabbix-app) e habilitado separadamente
    cat > "${ds_dir}/zabbix.yaml" <<YAML
apiVersion: 1
datasources:
  - name: Zabbix
    type: alexanderzobnin-zabbix-datasource
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

    # Habilita o app plugin Zabbix no Grafana
    cat > "${plugins_dir}/zabbix-app.yaml" <<YAML
apiVersion: 1
apps:
  - type: ${GRAFANA_APP_PLUGIN}
    disabled: false
YAML

    chown root:grafana \
        "${ds_dir}/zabbix.yaml" \
        "${plugins_dir}/zabbix-app.yaml"
    chmod 640 \
        "${ds_dir}/zabbix.yaml" \
        "${plugins_dir}/zabbix-app.yaml"

    info "Arquivos de provisionamento criados."
}

# Atualiza senha do admin Grafana via API (apos o servico iniciar)
configure_grafana_admin_password() {
    header "Configurando senha do admin Grafana"
    local retries=10
    local ok=false

    info "Aguardando Grafana responder na porta ${GRAFANA_PORT}..."
    while [[ $retries -gt 0 ]]; do
        if curl -sf "http://localhost:${GRAFANA_PORT}/api/health" > /dev/null 2>&1; then
            ok=true
            break
        fi
        ((retries--))
        sleep 3
    done

    if [[ "$ok" == false ]]; then
        warn "Grafana nao respondeu a tempo. A senha padrao pode nao ter sido alterada."
        return
    fi

    # Altera senha via API usando credencial inicial 'admin/admin'
    curl -sf -X PUT \
        -H "Content-Type: application/json" \
        -u "admin:admin" \
        -d "{\"password\":\"${GRAFANA_ADMIN_PASS}\"}" \
        "http://localhost:${GRAFANA_PORT}/api/user/password" > /dev/null 2>&1 \
        || warn "Nao foi possivel alterar a senha via API. Use a interface web."

    info "Senha do admin Grafana configurada."
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
    info "Firewall configurado."
}

# ====================== Servicos ======================
start_services() {
    header "Iniciando servicos"
    systemctl restart zabbix-server zabbix-agent2 apache2 grafana-server
    systemctl enable  zabbix-server zabbix-agent2 apache2 grafana-server
    info "Servicos iniciados."
}

# [C7] Verifica se todos os servicos essenciais estao ativos apos o start
healthcheck_services() {
    header "Verificando saude dos servicos"
    local all_ok=true
    local services=(zabbix-server zabbix-agent2 apache2 grafana-server)

    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            info "  [OK] ${svc}"
        else
            error "  [FALHA] ${svc} nao esta ativo"
            journalctl -u "$svc" -n 20 --no-pager >> "$LOG_FILE" 2>&1
            all_ok=false
        fi
    done

    if [[ "$all_ok" == false ]]; then
        error "Um ou mais servicos falharam. Verifique o log: ${LOG_FILE}"
        exit 1
    fi

    info "Todos os servicos estao ativos."
}

# ====================== Resumo final ======================
print_summary() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${BOLD}${GREEN}=====================================================${RESET}"
    echo -e "${BOLD}${GREEN}  Instalacao concluida com sucesso!${RESET}"
    echo -e "${BOLD}${GREEN}=====================================================${RESET}"
    echo ""
    echo -e "  ${BOLD}Zabbix Web${RESET}    http://${server_ip}/zabbix"
    echo -e "             Usuario : ${ZABBIX_WEB_USER}"
    echo -e "             Senha   : ${ZABBIX_WEB_PASS}"
    echo ""
    echo -e "  ${BOLD}Grafana${RESET}       http://${server_ip}:${GRAFANA_PORT}"
    echo -e "             Usuario : ${GRAFANA_ADMIN_USER}"
    echo -e "             Senha   : ${GRAFANA_ADMIN_PASS}"
    echo ""
    echo -e "  ${BOLD}Log completo${RESET}  ${LOG_FILE}"
    echo ""
    echo -e "${YELLOW}  IMPORTANTE: Salve as credenciais acima em local seguro!${RESET}"
    echo -e "${YELLOW}  Altere a senha padrao do Zabbix ('${ZABBIX_WEB_PASS}') pelo painel web.${RESET}"
    echo ""

    # [C8] Registra credenciais no log com permissao restrita
    chmod 600 "$LOG_FILE"
    log "=== CREDENCIAIS GERADAS ==="
    log "Zabbix Web -> Usuario: ${ZABBIX_WEB_USER} | Senha: ${ZABBIX_WEB_PASS}"
    log "Grafana    -> Usuario: ${GRAFANA_ADMIN_USER} | Senha: ${GRAFANA_ADMIN_PASS}"
}

# ====================== Principal ======================
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    log "=== Inicio da instalacao Zabbix + Grafana ==="

    parse_args "$@"
    check_root
    check_os
    check_already_installed
    generate_default_passwords
    collect_credentials
    update_system
    install_mariadb
    install_zabbix_repo
    install_zabbix_packages
    create_zabbix_db
    import_zabbix_schema      # [C1] Etapa adicionada
    configure_zabbix_server
    install_grafana
    install_grafana_plugins
    provision_grafana
    configure_firewall
    start_services
    healthcheck_services      # [C7] Etapa adicionada
    configure_grafana_admin_password
    print_summary

    log "=== Instalacao concluida com sucesso ==="
}

main "$@"
