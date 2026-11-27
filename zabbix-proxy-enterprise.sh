
#!/usr/bin/env bash
#
# ============================================================
# GDC ZABBIX PROXY ENTERPRISE INSTALLER
# Ubuntu Server 24.04 LTS / 26.04 LTS
#
# Docker Engine + Docker Compose
# Zabbix Proxy SQLite3
# Active Proxy + TLS PSK
#
# Persistencia: Docker Named Volume
# Backup automatico: DESABILITADO
# ============================================================

set -Eeuo pipefail
umask 077

# ------------------------------------------------------------
# CONFIGURACOES
# ------------------------------------------------------------

INSTALL_DIR="/opt/gdc-zabbix-proxy"
PROJECT_NAME="gdc-zabbix-proxy"
CONTAINER_NAME="gdc-zabbix-proxy"
VOLUME_NAME="gdc-zabbix-proxy-data"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $*"; }
die()  { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }

trap 'echo -e "${RED}[ERRO] Falha na linha $LINENO.${NC}" >&2' ERR

# ------------------------------------------------------------
# PRIVILEGIOS
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Sudo nao encontrado."
    exec sudo -E bash "$0" "$@"
fi

[[ -t 0 ]] || die "Execute em um terminal interativo."

# ------------------------------------------------------------
# VALIDACAO DO SISTEMA OPERACIONAL
# ------------------------------------------------------------

[[ -f /etc/os-release ]] || die "Sistema operacional nao identificado."

source /etc/os-release

[[ "$ID" == "ubuntu" ]] || die "Este instalador aceita somente Ubuntu."

case "$VERSION_ID" in
    24.04|26.04)
        log "Ubuntu Server $VERSION_ID identificado."
        ;;
    *)
        die "Versao nao suportada: $VERSION_ID. Utilize Ubuntu 24.04 ou 26.04 LTS."
        ;;
esac

UBUNTU_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

[[ -n "$UBUNTU_CODENAME" ]] || die "Codinome do Ubuntu nao identificado."

ARCH=$(dpkg --print-architecture)

case "$ARCH" in
    amd64|arm64|ppc64el)
        log "Arquitetura identificada: $ARCH"
        ;;
    *)
        die "Arquitetura nao suportada pelo instalador: $ARCH"
        ;;
esac

# ------------------------------------------------------------
# CABECALHO
# ------------------------------------------------------------

echo
echo "============================================================"
echo "          GDC - ZABBIX PROXY ENTERPRISE INSTALLER"
echo "============================================================"
echo "Sistema: Ubuntu $VERSION_ID ($UBUNTU_CODENAME)"
echo "Arquitetura: $ARCH"
echo "Banco: SQLite3"
echo "Comunicacao: Active Proxy"
echo "Seguranca: TLS PSK"
echo "Backup automatico: DESABILITADO"
echo "============================================================"
echo

# ------------------------------------------------------------
# PROTECAO CONTRA REINSTALACAO
# ------------------------------------------------------------

if [[ -e "$INSTALL_DIR" ]]; then
    die "Diretorio $INSTALL_DIR ja existe. Instalacao interrompida para proteger dados."
fi

# ------------------------------------------------------------
# ENTRADA DE DADOS
# ------------------------------------------------------------

echo "CONFIGURACAO DO PROXY"
echo

read -rp "Hostname do Proxy [$(hostname -s)]: " PROXY_HOSTNAME
PROXY_HOSTNAME=${PROXY_HOSTNAME:-$(hostname -s)}

[[ "$PROXY_HOSTNAME" =~ ^[a-zA-Z0-9._-]{1,128}$ ]] ||
    die "Hostname invalido."

echo

read -rp "IP ou DNS do Zabbix Server: " SERVER_HOST

[[ -n "$SERVER_HOST" ]] || die "Informe o endereco do Zabbix Server."

# Validacao de IPv4, IPv6 ou DNS
python3 - "$SERVER_HOST" <<'PY'
import ipaddress
import re
import sys

host = sys.argv[1]

try:
    ipaddress.ip_address(host)
except ValueError:
    hostname = host.rstrip(".")

    if len(hostname) > 253:
        sys.exit("Endereco muito longo.")

    pattern = (
        r"^(?=.{1,253}$)"
        r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)"
        r"(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$"
    )

    if not re.fullmatch(pattern, hostname):
        sys.exit("Endereco IP/DNS invalido.")
PY

read -rp "Porta do Zabbix Server [10051]: " SERVER_PORT
SERVER_PORT=${SERVER_PORT:-10051}

[[ "$SERVER_PORT" =~ ^[0-9]{1,5}$ ]] ||
    die "Porta invalida."

SERVER_PORT_NUM=$((10#$SERVER_PORT))

(( SERVER_PORT_NUM >= 1 && SERVER_PORT_NUM <= 65535 )) ||
    die "Porta fora do intervalo permitido."

SERVER_PORT="$SERVER_PORT_NUM"

# ------------------------------------------------------------
# VERSAO DO ZABBIX
# ------------------------------------------------------------

echo
echo "VERSAO DO ZABBIX"
echo "1 - Zabbix 7.4"
echo "2 - Zabbix 8.0 LTS"
echo

read -rp "Selecione a versao [1]: " VERSION_OPTION
VERSION_OPTION=${VERSION_OPTION:-1}

case "$VERSION_OPTION" in
    1)
        ZABBIX_VERSION="7.4-ubuntu-latest"
        ;;
    2)
        ZABBIX_VERSION="8.0-ubuntu-latest"
        ;;
    *)
        die "Opcao de versao invalida."
        ;;
esac

echo

# ------------------------------------------------------------
# IDENTIDADE TLS
# ------------------------------------------------------------

DEFAULT_IDENTITY="GDC-${PROXY_HOSTNAME}"

read -rp "Identidade TLS PSK [$DEFAULT_IDENTITY]: " TLS_IDENTITY
TLS_IDENTITY=${TLS_IDENTITY:-$DEFAULT_IDENTITY}

[[ "$TLS_IDENTITY" =~ ^[a-zA-Z0-9._:-]{1,128}$ ]] ||
    die "Identidade TLS invalida."

echo
echo "GERACAO DA CHAVE TLS PSK"
echo "1 - Gerar chave segura automaticamente"
echo "2 - Informar minha propria chave"
echo

read -rp "Opcao [1]: " PSK_OPTION
PSK_OPTION=${PSK_OPTION:-1}

case "$PSK_OPTION" in
    1)
        command -v openssl >/dev/null 2>&1 ||
            die "OpenSSL nao encontrado."

        TLS_PSK=$(openssl rand -hex 32)
        ;;
    2)
        read -rsp "Digite a chave PSK hexadecimal: " TLS_PSK
        echo

        [[ "$TLS_PSK" =~ ^[a-fA-F0-9]{32,512}$ ]] ||
            die "PSK invalida. Utilize de 32 a 512 caracteres hexadecimais."

        (( ${#TLS_PSK} % 2 == 0 )) ||
            die "A quantidade de caracteres da PSK deve ser par."
        ;;
    *)
        die "Opcao de PSK invalida."
        ;;
esac

# ------------------------------------------------------------
# DETECCAO DE RECURSOS
# ------------------------------------------------------------

TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)

if (( TOTAL_RAM_MB >= 8192 )); then
    CACHE_SIZE="128M"
    HISTORY_CACHE_SIZE="128M"
    HISTORY_INDEX_CACHE_SIZE="32M"
elif (( TOTAL_RAM_MB >= 4096 )); then
    CACHE_SIZE="64M"
    HISTORY_CACHE_SIZE="64M"
    HISTORY_INDEX_CACHE_SIZE="16M"
else
    CACHE_SIZE="32M"
    HISTORY_CACHE_SIZE="32M"
    HISTORY_INDEX_CACHE_SIZE="8M"
fi

# Endpoint com suporte a IPv4, DNS e IPv6
if [[ "$SERVER_HOST" == *:* ]]; then
    SERVER_ENDPOINT="[${SERVER_HOST}]:${SERVER_PORT}"
else
    SERVER_ENDPOINT="${SERVER_HOST}:${SERVER_PORT}"
fi

# ------------------------------------------------------------
# CONFIRMACAO
# ------------------------------------------------------------

echo
echo "============================================================"
echo "RESUMO DA INSTALACAO"
echo "============================================================"
echo "Proxy:             $PROXY_HOSTNAME"
echo "Servidor central:  $SERVER_ENDPOINT"
echo "Versao:            $ZABBIX_VERSION"
echo "Modo:              ACTIVE"
echo "Banco:             SQLITE3"
echo "Criptografia:      TLS PSK"
echo "Identidade PSK:    $TLS_IDENTITY"
echo "Memoria detectada: ${TOTAL_RAM_MB} MB"
echo "Cache:             $CACHE_SIZE"
echo "Historico:         $HISTORY_CACHE_SIZE"
echo "Backup:            DESABILITADO"
echo "Diretorio:         $INSTALL_DIR"
echo "============================================================"
echo

read -rp "Deseja iniciar a instalacao? (S/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
    unset TLS_PSK
    echo "Instalacao cancelada."
    exit 0
fi

# ------------------------------------------------------------
# DEPENDENCIAS
# ------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive

log "Atualizando indice de pacotes..."
apt-get update

log "Instalando dependencias..."
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    openssl \
    python3 \
    dnsutils \
    netcat-openbsd

# ------------------------------------------------------------
# REPOSITORIO OFICIAL DO DOCKER
# ------------------------------------------------------------

log "Configurando repositorio oficial Docker..."

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update

log "Instalando Docker Engine e Compose..."

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable docker
systemctl start docker

docker info >/dev/null ||
    die "Docker nao esta funcionando."

docker compose version >/dev/null ||
    die "Docker Compose nao esta disponivel."

log "Docker instalado e operacional."

# ------------------------------------------------------------
# PROTECAO CONTRA RECURSOS EXISTENTES
# ------------------------------------------------------------

if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    die "Container $CONTAINER_NAME ja existe."
fi

if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    die "Volume $VOLUME_NAME ja existe. Verifique os dados antes de continuar."
fi

# ------------------------------------------------------------
# DIRETORIOS
# ------------------------------------------------------------

log "Criando estrutura de instalacao..."

install -d -m 0750 "$INSTALL_DIR"
install -d -m 0700 "$INSTALL_DIR/secrets"

# ------------------------------------------------------------
# ARMAZENAMENTO DA PSK
# ------------------------------------------------------------

log "Armazenando chave TLS PSK..."

printf '%s' "$TLS_PSK" > "$INSTALL_DIR/secrets/proxy.psk"

# A pasta no host fica restrita ao root.
# O arquivo fica legivel dentro do container.
chmod 0444 "$INSTALL_DIR/secrets/proxy.psk"
chmod 0700 "$INSTALL_DIR/secrets"

unset TLS_PSK

# ------------------------------------------------------------
# ARQUIVO ENV
# ------------------------------------------------------------

log "Criando configuracao de ambiente..."

cat > "$INSTALL_DIR/.env" <<EOF
ZABBIX_VERSION=${ZABBIX_VERSION}
PROXY_HOSTNAME=${PROXY_HOSTNAME}
SERVER_ENDPOINT=${SERVER_ENDPOINT}
TLS_IDENTITY=${TLS_IDENTITY}
CACHE_SIZE=${CACHE_SIZE}
HISTORY_CACHE_SIZE=${HISTORY_CACHE_SIZE}
HISTORY_INDEX_CACHE_SIZE=${HISTORY_INDEX_CACHE_SIZE}
EOF

chmod 0600 "$INSTALL_DIR/.env"

# ------------------------------------------------------------
# DOCKER COMPOSE
# ------------------------------------------------------------

log "Criando Docker Compose..."

cat > "$INSTALL_DIR/docker-compose.yml" <<'EOF'
services:
  zabbix-proxy:
    image: zabbix/zabbix-proxy-sqlite3:${ZABBIX_VERSION}
    container_name: gdc-zabbix-proxy
    hostname: ${PROXY_HOSTNAME}
    init: true
    restart: unless-stopped

    environment:
      ZBX_HOSTNAME: ${PROXY_HOSTNAME}
      ZBX_SERVER_HOST: ${SERVER_ENDPOINT}
      ZBX_PROXYMODE: "0"

      ZBX_TLSCONNECT: psk
      ZBX_TLSPSKIDENTITY: ${TLS_IDENTITY}
      ZBX_TLSPSKFILE: /run/zabbix/secrets/tls/proxy.psk

      ZBX_CACHESIZE: ${CACHE_SIZE}
      ZBX_HISTORYCACHESIZE: ${HISTORY_CACHE_SIZE}
      ZBX_HISTORYINDEXCACHESIZE: ${HISTORY_INDEX_CACHE_SIZE}

      ZBX_PROXYCONFIGFREQUENCY: "300"
      ZBX_HEARTBEATFREQUENCY: "60"

      ZBX_STARTPOLLERS: "10"
      ZBX_STARTPINGERS: "2"
      ZBX_STARTSNMPPOLLERS: "5"
      ZBX_STARTDBSYNCERS: "4"

      ZBX_TIMEOUT: "10"
      ZBX_LOGSLOWQUERIES: "3000"

    volumes:
      - proxy-data:/var/lib/zabbix/db_data
      - ./secrets/proxy.psk:/run/zabbix/secrets/tls/proxy.psk:ro

    cap_add:
      - NET_RAW

    stop_grace_period: 30s

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"

volumes:
  proxy-data:
    name: gdc-zabbix-proxy-data
EOF

chmod 0640 "$INSTALL_DIR/docker-compose.yml"

# ------------------------------------------------------------
# VALIDACAO DA CONFIGURACAO
# ------------------------------------------------------------

log "Validando Docker Compose..."

cd "$INSTALL_DIR"

docker compose -p "$PROJECT_NAME" config -q ||
    die "Erro na configuracao Docker Compose."

# ------------------------------------------------------------
# TESTE DE DNS E CONECTIVIDADE
# ------------------------------------------------------------

log "Verificando resolucao do servidor central..."

if ! getent ahosts "$SERVER_HOST" >/dev/null 2>&1; then
    warn "Nao foi possivel resolver o endereco do servidor."
    warn "Verifique DNS e conectividade."
fi

log "Verificando conectividade TCP..."

if timeout 5 nc -z "$SERVER_HOST" "$SERVER_PORT" >/dev/null 2>&1; then
    log "Conexao TCP com o servidor central confirmada."
else
    warn "Conexao TCP nao confirmada."
    warn "Verifique firewall, rota e disponibilidade do servidor."
fi

# ------------------------------------------------------------
# CRIACAO DO VOLUME
# ------------------------------------------------------------

log "Criando volume persistente SQLite3..."

docker volume create "$VOLUME_NAME" >/dev/null

# ------------------------------------------------------------
# DOWNLOAD DA IMAGEM
# ------------------------------------------------------------

log "Baixando imagem oficial do Zabbix..."

docker compose -p "$PROJECT_NAME" pull

# ------------------------------------------------------------
# INICIALIZACAO
# ------------------------------------------------------------

log "Iniciando Zabbix Proxy Enterprise..."

docker compose -p "$PROJECT_NAME" up -d

# ------------------------------------------------------------
# VALIDACAO DO CONTAINER
# ------------------------------------------------------------

log "Aguardando inicializacao do Proxy..."

CONTAINER_READY=false

for attempt in $(seq 1 12); do
    if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        CONTAINER_STATE=$(docker inspect \
            -f '{{.State.Status}}' "$CONTAINER_NAME")

        if [[ "$CONTAINER_STATE" == "running" ]]; then
            CONTAINER_READY=true
            break
        fi
    fi

    sleep 5
done

if [[ "$CONTAINER_READY" != "true" ]]; then
    docker compose -p "$PROJECT_NAME" logs --tail=100
    die "Container nao iniciou corretamente."
fi

log "Container em execucao."

# ------------------------------------------------------------
# VALIDACAO DA PSK
# ------------------------------------------------------------

if ! docker exec --user zabbix "$CONTAINER_NAME" \
    test -r /run/zabbix/secrets/tls/proxy.psk; then

    docker compose -p "$PROJECT_NAME" logs --tail=100
    die "O usuario Zabbix nao conseguiu acessar a PSK."
fi

log "Arquivo TLS PSK acessivel pelo usuario Zabbix."

# ------------------------------------------------------------
# INFORMACOES DA IMAGEM
# ------------------------------------------------------------

echo
echo "VERSAO DO ZABBIX:"
docker exec "$CONTAINER_NAME" zabbix_proxy -V | head -n 2

# ------------------------------------------------------------
# RESULTADO FINAL
# ------------------------------------------------------------

echo
echo "============================================================"
echo "        GDC ZABBIX PROXY ENTERPRISE - INSTALADO"
echo "============================================================"

echo
echo "CONTAINER:"
docker ps --filter "name=$CONTAINER_NAME"

echo
echo "VOLUME PERSISTENTE:"
docker volume inspect "$VOLUME_NAME" \
    --format '{{.Name}} - {{.Mountpoint}}'

echo
echo "DIRETORIO:"
echo "$INSTALL_DIR"

echo
echo "CONFIGURACAO:"
echo "Hostname: $PROXY_HOSTNAME"
echo "Servidor: $SERVER_ENDPOINT"
echo "Modo: ACTIVE"
echo "Banco: SQLITE3"
echo "TLS: PSK"
echo "Identidade PSK: $TLS_IDENTITY"

echo
echo "============================================================"
echo "COMANDOS ADMINISTRATIVOS"
echo "============================================================"

echo "Status:"
echo "docker ps"

echo
echo "Logs:"
echo "docker logs -f $CONTAINER_NAME"

echo
echo "Reiniciar:"
echo "cd $INSTALL_DIR && docker compose restart"

echo
echo "Parar:"
echo "cd $INSTALL_DIR && docker compose stop"

echo
echo "Iniciar:"
echo "cd $INSTALL_DIR && docker compose up -d"

echo
echo "Consumo de recursos:"
echo "docker stats $CONTAINER_NAME"

echo
echo "Validar configuracao:"
echo "cd $INSTALL_DIR && docker compose config -q"

echo
echo "Consultar PSK (acesso restrito ao root):"
echo "sudo cat $INSTALL_DIR/secrets/proxy.psk"

echo
echo "============================================================"
echo "IMPORTANTE"
echo "============================================================"
echo "1. Cadastre o Proxy no servidor Zabbix."
echo "2. Utilize o mesmo nome informado no instalador."
echo "3. Configure o Proxy como ACTIVE."
echo "4. Configure criptografia PSK no cadastro do Proxy."
echo "5. Informe a identidade e a PSK armazenadas no servidor."
echo "6. O servidor central deve permitir TCP 10051."
echo "7. Nao apague o diretorio secrets nem o volume SQLite."
echo "8. Backup automatico: DESABILITADO."
echo "============================================================"

echo
log "Instalacao finalizada."
