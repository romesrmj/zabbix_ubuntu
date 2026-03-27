#!/usr/bin/env bash
# ==============================================================================
#  rollback_zabbix_grafana.sh
#  Remove COMPLETAMENTE: Zabbix 7.0 + Grafana OSS + MariaDB + todos os arquivos
#  de configuracao, dados, repositorios e chaves GPG instalados pelo script
#  install_zabbix_grafana.sh no Ubuntu 24.04 LTS.
#
#  Uso:
#    sudo bash rollback_zabbix_grafana.sh              # interativo (confirma antes)
#    sudo bash rollback_zabbix_grafana.sh --force      # sem confirmacao (CI/CD)
#
#  ATENCAO: este script e DESTRUTIVO e IRREVERSIVEL.
#  Todos os dados do banco Zabbix serao perdidos permanentemente.
# ==============================================================================

set -Eeuo pipefail
trap 'echo "[ERRO] Falha na linha ${LINENO}. Saindo." >&2; exit 1' ERR

# ==============================================================================
# Configuracao
# ==============================================================================
readonly LOG_FILE="/var/log/zabbix_grafana_rollback.log"
readonly GRAFANA_PLUGIN="alexanderzobnin-zabbix-app, marcusolsson-dynamictext-panel"
FORCE=false

# ==============================================================================
# Utilitarios
# ==============================================================================
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info()   { echo -e "${GREEN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[AVISO]${RESET} $*" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[ERRO]${RESET}  $*" | tee -a "$LOG_FILE" >&2; }
header() { echo -e "\n${BOLD}${CYAN}==> $*${RESET}" | tee -a "$LOG_FILE"; }

# Remove arquivo ou diretorio com log
remove() {
    local target="$1"
    if [[ -e "$target" || -L "$target" ]]; then
        rm -rf "$target"
        log "  removido: $target"
    fi
}

# ==============================================================================
# Argumentos
# ==============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) FORCE=true ;;
            --help|-h)
                echo "Uso: sudo $0 [--force]"
                echo "  --force   Nao pede confirmacao (uso em pipelines)"
                exit 0 ;;
            *) error "Argumento desconhecido: $1"; exit 1 ;;
        esac
        shift
    done
}

# ==============================================================================
# Verificacoes
# ==============================================================================
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "Execute como root: sudo $0"
        exit 1
    fi
}

confirm() {
    if [[ "$FORCE" == true ]]; then
        warn "Modo --force ativo. Pulando confirmacao."
        return
    fi

    echo -e "\n${RED}${BOLD}ATENCAO — OPERACAO IRREVERSIVEL${RESET}"
    echo "Este script vai remover permanentemente:"
    echo "  - Zabbix Server, Frontend, Agent2 e todos os plugins"
    echo "  - Grafana OSS e o plugin Zabbix"
    echo "  - MariaDB e o banco de dados 'zabbix' com TODOS os dados"
    echo "  - Apache2 (se instalado exclusivamente pelo Zabbix)"
    echo "  - Todos os arquivos de configuracao, logs e repositorios"
    echo ""
    read -rp "Tem certeza? Digite 'CONFIRMO' para continuar: " ans
    if [[ "$ans" != "CONFIRMO" ]]; then
        info "Rollback cancelado."
        exit 0
    fi
}

# ==============================================================================
# 1. Para e desabilita todos os servicos
# ==============================================================================
stop_services() {
    header "Parando e desabilitando servicos"
    local services=(
        zabbix-server
        zabbix-agent
        zabbix-agent2
        grafana-server
        apache2
        mariadb
    )
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" 2>/dev/null && log "  parado:      $svc" || true
        fi
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl disable "$svc" 2>/dev/null && log "  desabilitado: $svc" || true
        fi
    done
    info "Servicos parados."
}

# ==============================================================================
# 2. Remove pacotes Zabbix
# ==============================================================================
remove_zabbix_packages() {
    header "Removendo pacotes Zabbix"
    local pkgs=(
        zabbix-server-mysql
        zabbix-frontend-php
        zabbix-apache-conf
        zabbix-sql-scripts
        zabbix-agent
        zabbix-agent2
        zabbix-agent2-plugin-mongodb
        zabbix-agent2-plugin-mssql
        zabbix-agent2-plugin-postgresql
        zabbix-release
        zabbix-get
        zabbix-sender
        zabbix-js
        zabbix-web-service
    )
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${pkgs[@]}" 2>/dev/null || true
    info "Pacotes Zabbix removidos."
}

# ==============================================================================
# 3. Remove Apache2
#    Verifica se ha outros virtual hosts antes de remover
# ==============================================================================
remove_apache2() {
    header "Removendo Apache2"
    local other_sites
    other_sites=$(find /etc/apache2/sites-enabled/ -type f ! -name "zabbix*" 2>/dev/null | wc -l)
    if [[ "$other_sites" -gt 0 ]]; then
        warn "Apache2 tem outros virtual hosts ativos ($other_sites). Removendo apenas config do Zabbix."
        a2disconf zabbix 2>/dev/null || true
        rm -f /etc/apache2/conf-available/zabbix.conf
        rm -f /etc/apache2/conf-enabled/zabbix.conf
        systemctl restart apache2 2>/dev/null || true
        info "Configuracao Zabbix removida do Apache2 (Apache mantido)."
    else
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq apache2 apache2-* libapache2-* 2>/dev/null || true
        info "Apache2 removido."
    fi
}

# ==============================================================================
# 4. Remove Grafana e plugin
# ==============================================================================
remove_grafana() {
    header "Removendo Grafana OSS"

    # Remove plugin antes de purgar o pacote
    if command -v grafana-cli &>/dev/null; then
        grafana-cli plugins remove "$GRAFANA_PLUGIN" 2>/dev/null || true
        log "  plugin ${GRAFANA_PLUGIN} removido."
    fi

    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq grafana 2>/dev/null || true
    info "Grafana removido."
}

# ==============================================================================
# 5. Remove MariaDB e banco de dados Zabbix
# ==============================================================================
remove_mariadb() {
    header "Removendo MariaDB e banco de dados Zabbix"

    # Tenta dropar o banco antes de purgar (MariaDB ainda em execucao neste ponto)
    if systemctl is-active --quiet mariadb 2>/dev/null; then
        mysql -uroot -e "DROP DATABASE IF EXISTS zabbix;" 2>/dev/null && \
            log "  banco 'zabbix' removido." || true
        # Remove usuario do banco (tenta ambos os nomes comuns)
        mysql -uroot -e "DROP USER IF EXISTS 'zabbix'@'localhost';" 2>/dev/null || true
        mysql -uroot -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    fi

    systemctl stop mariadb 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
        mariadb-server mariadb-client mariadb-common \
        mysql-common 2>/dev/null || true
    info "MariaDB removido."
}

# ==============================================================================
# 6. Remove arquivos de configuracao, dados e logs
# ==============================================================================
remove_config_files() {
    header "Removendo arquivos de configuracao e dados"

    # Zabbix
    remove /etc/zabbix
    remove /var/lib/zabbix
    remove /var/log/zabbix
    remove /usr/share/zabbix
    remove /usr/share/zabbix-sql-scripts
    remove /run/zabbix

    # Grafana
    remove /etc/grafana
    remove /var/lib/grafana
    remove /var/log/grafana
    remove /usr/share/grafana
    remove /run/grafana

    # MariaDB / MySQL
    remove /var/lib/mysql
    remove /var/log/mysql
    remove /etc/mysql

    # Apache Zabbix
    remove /etc/apache2/conf-available/zabbix.conf
    remove /etc/apache2/conf-enabled/zabbix.conf

    # Logs deste script de instalacao
    remove /var/log/zabbix_grafana_install.log

    info "Arquivos de configuracao e dados removidos."
}

# ==============================================================================
# 7. Remove repositorios e chaves GPG
# ==============================================================================
remove_repos() {
    header "Removendo repositorios e chaves GPG"

    # Zabbix
    remove /etc/apt/sources.list.d/zabbix.list
    remove /etc/apt/sources.list.d/zabbix-release.list

    # Grafana — ambos os caminhos possiveis (legado e atual)
    remove /etc/apt/sources.list.d/grafana.list
    remove /etc/apt/keyrings/grafana.gpg
    remove /usr/share/keyrings/grafana.gpg

    # Zabbix GPG (pode ter sido adicionada via dpkg)
    apt-key del "$(apt-key list 2>/dev/null | grep -B1 -i zabbix | grep pub | awk '{print $2}' | cut -d/ -f2)" 2>/dev/null || true

    apt-get update -qq 2>/dev/null || true
    info "Repositorios e chaves GPG removidos."
}

# ==============================================================================
# 8. Remove usuarios e grupos do sistema
# ==============================================================================
remove_system_users() {
    header "Removendo usuarios e grupos do sistema"

    for user in zabbix grafana; do
        if id "$user" &>/dev/null; then
            userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
            log "  usuario removido: $user"
        fi
    done

    for group in zabbix grafana; do
        if getent group "$group" &>/dev/null; then
            groupdel "$group" 2>/dev/null || true
            log "  grupo removido: $group"
        fi
    done

    info "Usuarios e grupos removidos."
}

# ==============================================================================
# 9. Remove pacotes de dependencias orfaos
# ==============================================================================
remove_orphans() {
    header "Removendo dependencias orfas"
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq 2>/dev/null || true
    apt-get autoclean -qq 2>/dev/null || true
    info "Limpeza de dependencias concluida."
}

# ==============================================================================
# 10. Verifica se sobrou alguma coisa
# ==============================================================================
verify_removal() {
    header "Verificando remocao"
    local issues=0

    # Servicos
    for svc in zabbix-server zabbix-agent2 grafana-server mariadb; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            warn "Servico ainda ativo: $svc"
            issues=$(( issues + 1 ))
        fi
    done

    # Pacotes
    local remaining_pkgs
    remaining_pkgs=$(dpkg -l 2>/dev/null \
        | awk '/^ii/ {print $2}' \
        | grep -E '^(zabbix|grafana|mariadb-server)' || true)
    if [[ -n "$remaining_pkgs" ]]; then
        warn "Pacotes ainda instalados:"
        echo "$remaining_pkgs" | while read -r p; do warn "  - $p"; done
        issues=$(( issues + 1 ))
    fi

    # Diretorios principais
    for dir in /etc/zabbix /var/lib/zabbix /etc/grafana /var/lib/grafana /var/lib/mysql; do
        if [[ -d "$dir" ]]; then
            warn "Diretorio ainda presente: $dir"
            issues=$(( issues + 1 ))
        fi
    done

    if [[ $issues -eq 0 ]]; then
        info "Verificacao concluida: nenhum residuo encontrado."
    else
        warn "Verificacao concluida com ${issues} aviso(s). Veja o log: $LOG_FILE"
    fi
}

# ==============================================================================
# Resumo final
# ==============================================================================
print_summary() {
    echo -e "\n${CYAN}"
    cat <<'BANNER'
 ██████╗  ██████╗ ██╗     ██╗      ██████╗  █████╗  ██████╗██╗  ██╗
 ██╔══██╗██╔═══██╗██║     ██║     ██╔══██╗██╔══██╗██╔════╝██║ ██╔╝
 ██████╔╝██║   ██║██║     ██║     ██████╔╝███████║██║     █████╔╝
 ██╔══██╗██║   ██║██║     ██║     ██╔══██╗██╔══██║██║     ██╔═██╗
 ██║  ██║╚██████╔╝███████╗███████╗██████╔╝██║  ██║╚██████╗██║  ██╗
 ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚══════╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝
BANNER
    echo -e "${RESET}"
    echo -e "${BOLD}Rollback concluido!${RESET}"
    echo
    echo "  O sistema foi restaurado ao estado anterior a instalacao."
    echo
    echo -e "  ${BOLD}Removido:${RESET}"
    echo "    - Zabbix Server, Frontend, Agent2 e plugins"
    echo "    - Grafana OSS e plugin Zabbix"
    echo "    - MariaDB e banco de dados 'zabbix'"
    echo "    - Apache2 (se nao havia outros sites ativos)"
    echo "    - Todos os arquivos de configuracao e dados"
    echo "    - Repositorios apt e chaves GPG"
    echo "    - Usuarios e grupos do sistema"
    echo
    echo -e "  ${BOLD}Log completo:${RESET} $LOG_FILE"
    echo
    echo -e "  ${YELLOW}Recomendacao:${RESET} reinicie o servidor para garantir que"
    echo "  nenhum processo residual permaneca em memoria."
    echo "    sudo reboot"
    echo
}

# ==============================================================================
# Ponto de entrada principal
# ==============================================================================
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    log "=== Inicio do rollback Zabbix + Grafana ==="

    parse_args "$@"
    check_root
    confirm

    stop_services
    remove_zabbix_packages
    remove_apache2
    remove_grafana
    remove_mariadb
    remove_config_files
    remove_repos
    remove_system_users
    remove_orphans
    verify_removal
    print_summary

    log "=== Rollback concluido ==="
}

main "$@"
