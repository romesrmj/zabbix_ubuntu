
#!/usr/bin/env bash
#
# ============================================================
# GDC ZABBIX PROXY ENTERPRISE INSTALLER
# Ubuntu Server 24.04 LTS
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
# CONFIGURACOES PADRAO
# ------------------------------------------------------------

INSTALL_DIR="/opt/gdc-zabbix-proxy"
PROJECT_NAME="gdc-zabbix-proxy"
CONTAINER_NAME="gdc-zabbix-proxy"
VOLUME_NAME="gdc-zabbix-proxy-data"

DEFAULT_VERSION="7.4-ubuntu-latest"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[OK]${NC} $*"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[AVISO]${NC} $*"
}

die() {
    echo -e "${RED}[ERRO]${NC} $*" >&2
    exit 1
}

trap 'echo -e "${RED}[ERRO] Falha na linha $LINENO. Consulte a mensagem anterior.${NC}" >&2' ERR

# ------------------------------------------------------------
# VALIDACAO DE PRIVILEGIOS
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Sudo nao encontrado."
    exec sudo -E bash "$0" "$@"
fi

[[ -t 0 ]] || die "Execute em um terminal interativo."

[[ -f /etc/os-release ]] || die "Sistema operacional nao identificado."

source /etc/os-release

[[ "$ID" == "ubuntu" ]] || die "Sistema operacional deve ser Ubuntu."

[[ "$VERSION_ID" == "24.04" ]] || die "Utilize Ubuntu Server 24.04 LTS."

# ------------------------------------------------------------
# CABECALHO
# ------------------------------------------------------------

clear

echo
echo "============================================================"
echo "          GDC - ZABBIX PROXY ENTERPRISE INSTALLER"
echo "============================================================"
echo "Sistema: Ubuntu Server 24.04"
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

if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    die "Container $CONTAINER_NAME ja existe."
fi

if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    die "Volume $VOLUME_NAME ja existe. Verifique os dados antes de continuar."
fi

# ------------------------------------------------------------
# ENTRADA DE DADOS
# ------------------------------------------------------------

echo "CONFIGURACAO DO PROXY"
echo

read -rp "Hostname do Proxy (cadastro no Zabbix): " PROXY_HOSTNAME

PROXY_HOSTNAME=${PROXY_HOSTNAME:-$(hostname -s)}

[[ "$PROXY_HOSTNAME" =~ ^[a-zA-Z0-9._-]{1,128}$ ]] ||
    die "Hostname invalido."

echo

read -rp "IP ou DNS do Zabbix Server: " SERVER_HOST

[[ -n "$SERVER_HOST" ]] || die "Informe o endereco do Zabbix Server."

# Validar IP ou DNS
python3 - "$SERVER_HOST" <<'PY'
import ipaddress
import re
import sys

host = sys.argv[1]

try:
    ipaddress.ip_address(host)
except ValueError:
    if len(host) > 253:
        sys.exit("Endereco muito longo.")

    pattern = r'^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$'

    if not re.match(pattern, host):
        sys.exit("Endereco IP/DNS invalido.")
PY

read -rp "Porta do Zabbix Server [10051]: " SERVER_PORT
SERVER_PORT=${SERVER_PORT:-10051}

[[ "$SERVER_PORT" =~ ^[0-9]{1,5}$ ]] ||
    die "Porta invalida."

(( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) ||
    die "Porta fora do intervalo permitido."

echo

echo "VERSAO DO ZABBIX"
echo "1 - Zabbix 7.4 (compatibilidade com servidor 7.4)"
echo "2 - Zabbix 8.0 LTS (utilizar com servidor 8.0)"
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

read -rp "Identidade TLS PSK [${DEFAULT_IDENTITY}]: " TLS_IDENTITY
TLS_IDENTITY=${TLS_IDENTITY:-$DEFAULT_IDENTITY}

[[ "$TLS_IDENTITY" =~ ^[a-zA-Z0-9._:-]{1,128}$ ]] ||
    die "Identidade TLS invalida."

echo
echo "GERACAO DA CHAVE TLS PSK"
echo "1 - Gerar chave segura automaticamente (recomendado)"
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

# Endpoint IPv4/DNS ou IPv6
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
echo "Banco:             SQLite3"
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

[[ "$CONFIRM" =~ ^[Ss]$ ]] || {
    unset TLS_PSK
    echo "Instalacao cancelada."
    exit 0
}

# ------------------------------------------------------------
# INSTALACAO DE DEPENDENCIAS
# ------------------------------------------------------------

log "Atualizando indice de pacotes..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

log "Instalando dependencias..."

apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    openssl \
    python3 \
    jq \
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

ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
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
# DIRETORIOS
# ------------------------------------------------------------

log "Criando estrutura de instalacao..."

install -d -m 0750 "$INSTALL_DIR"
install -d -m 0700 "$INSTALL_DIR/secrets"

# ------------------------------------------------------------
# ARMAZENAMENTO DA PSK
# ------------------------------------------------------------

log "Armazenando chave TLS PSK protegida..."

printf '%s' "$TLS_PSK" > "$INSTALL_DIR/secrets/proxy.psk"

# Docker Compose local monta o arquivo como secret.
# A pasta no host permanece acessivel apenas ao root.
chmod 0444 "$INSTALL_DIR/secrets/proxy.psk"
chmod 0700 "$INSTALL_DIR/secrets"

unset TLS_PSK

# ------------------------------------------------------------
# ARQUIVO ENV
# SEM SENHAS OU CHAVES SECRETAS
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

log "Criando Docker Compose Enterprise..."

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

      ZBX_TLSPSKFILE: /run/secrets/proxy_psk

      ZBX_CACHESIZE: ${CACHE_SIZE}

      ZBX_HISTORYCACHESIZE: ${HISTORY_CACHE_SIZE}

      ZBX_HISTORYINDEXCACHESIZE: ${HISTORY_INDEX_CACHE_SIZE}

      ZBX_CONFIGFREQUENCY: "300"

      ZBX_HEARTBEATFREQUENCY: "60"

      ZBX_STARTPOLLERS: "10"

      ZBX_STARTPINGERS: "2"

      ZBX_STARTSNMPPOLLERS: "5"

      ZBX_STARTDBSYNCERS: "4"

      ZBX_TIMEOUT: "10"

      ZBX_LOGSLOWQUERIES: "3000"

    volumes:

      - proxy-data:/var/lib/zabbix/db_data

    secrets:

      - source: proxy_psk
        target: proxy_psk

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

secrets:

  proxy_psk:
    file: ./secrets/proxy.psk

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
    warn "Verifique DNS e conectividade antes de cadastrar o Proxy."
fi

log "Verificando conectividade TCP com o servidor..."

if timeout 5 nc -z "$SERVER_HOST" "$SERVER_PORT" >/dev/null 2>&1; then
    log "Conexao TCP com o servidor central confirmada."
else
    warn "Conexao TCP nao confirmada neste momento."
    warn "O firewall ou a rota podem estar bloqueando a comunicacao."
    warn "A instalacao continuara, mas o Proxy precisa alcancar o servidor."
fi

# ------------------------------------------------------------
# CRIACAO DO VOLUME PERSISTENTE
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

log "Aguardando inicializacao..."

sleep 20

if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    docker compose -p "$PROJECT_NAME" logs --tail=100
    die "Container nao encontrado."
fi

CONTAINER_STATE=$(docker inspect \
    -f '{{.State.Status}}' "$CONTAINER_NAME")

if [[ "$CONTAINER_STATE" != "running" ]]; then
    docker compose -p "$PROJECT_NAME" logs --tail=100
    die "Container nao iniciou corretamente."
fi

log "Container em execucao."

# ------------------------------------------------------------
# VALIDACAO DA PSK DENTRO DO CONTAINER
# ------------------------------------------------------------

if ! docker exec "$CONTAINER_NAME" \
    test -r /run/secrets/proxy_psk; then

    docker compose -p "$PROJECT_NAME" logs --tail=100
    die "O container nao conseguiu acessar a PSK."
fi

log "Arquivo TLS PSK acessivel pelo container."

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
echo "          CREDENCIAIS PARA O ZABBIX SERVER"
echo "============================================================"

echo
echo "Proxy name:"
echo "$PROXY_HOSTNAME"

echo
echo "Encryption identity:"
echo "$TLS_IDENTITY"

echo
echo "PSK:"
cat "$INSTALL_DIR/secrets/proxy.psk"

echo
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
echo "============================================================"
echo "IMPORTANTE:"
echo "============================================================"
echo "1. Cadastre o Proxy no servidor Zabbix."
echo "2. Configure o modo ACTIVE."
echo "3. Configure a criptografia PSK."
echo "4. Informe a identidade e a chave exibidas acima."
echo "5. O servidor central deve permitir a comunicacao TCP 10051."
echo "6. Nao apague o diretorio secrets nem o volume SQLite."
echo "7. Backup automatico: DESABILITADO."
echo "============================================================"

echo
log "Instalacao finalizada."
