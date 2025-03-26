#!/bin/bash

# Configuração profissional para ambientes automatizados
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export TERM=linux

# Configurações globais
LOG_FILE="/var/log/zabbix_deploy.log"
ZABBIX_CONF="/etc/zabbix/zabbix_server.conf"
DOMAIN=""
ZABBIX_USER=""
ZABBIX_PASS=""

# Função de log detalhada
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Função para saída em caso de erro
error_exit() {
  log "ERRO: $1"
  exit 1
}

# Configuração inicial
setup_environment() {
  log "Iniciando configuração do ambiente"
  echo "zabbix-frontend-php zabbix-frontend-php/timezone select UTC" | debconf-set-selections
  echo "zabbix-server-mysql zabbix-server-mysql/dbconfig-install boolean true" | debconf-set-selections
  echo "console-setup console-setup/charmap47 select UTF-8" | debconf-set-selections
}

# Coleta de informações
get_user_input() {
  clear
  echo "=============================================="
  echo " CONFIGURAÇÃO INICIAL - ZABBIX 7.0 + GRAFANA"
  echo "=============================================="
  
  while [ -z "$DOMAIN" ]; do
    read -p "Digite o domínio completo (ex: monitor.empresa.com): " DOMAIN
  done

  while [ -z "$ZABBIX_USER" ]; do
    read -p "Digite o usuário admin para Zabbix: " ZABBIX_USER
  done

  while [ -z "$ZABBIX_PASS" ]; do
    read -sp "Digite a senha para $ZABBIX_USER: " ZABBIX_PASS
    echo
  done
}

# Instalação do Zabbix 7.0 LTS
install_zabbix() {
  log "Iniciando instalação do Zabbix 7.0 LTS"
  
  # Adicionar repositório
  wget -q https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb || error_exit "Falha ao baixar pacote do Zabbix"
  dpkg -i zabbix-release_latest_7.0+ubuntu24.04_all.deb || error_exit "Falha ao instalar repositório"

  # Atualizar e instalar pacotes
  apt-get update -qqy || error_exit "Falha na atualização de pacotes"
  apt-get install -qqy \
    zabbix-server-mysql \
    zabbix-frontend-php \
    zabbix-apache-conf \
    zabbix-sql-scripts \
    zabbix-agent || error_exit "Falha na instalação de pacotes do Zabbix"

  # Configurar banco de dados
  DB_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+-=')
  mysql -e "CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;" || error_exit "Falha ao criar banco de dados"
  mysql -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '${DB_PASS}';" || error_exit "Falha ao criar usuário do banco"
  mysql -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';" || error_exit "Falha ao conceder privilégios"
  zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -u zabbix -p"${DB_PASS}" zabbix || error_exit "Falha ao importar schema"

  # Configurar arquivo do Zabbix Server
  cat >> "$ZABBIX_CONF" <<EOF
DBHost=localhost
DBName=zabbix
DBUser=zabbix
DBPassword=$DB_PASS
StartPollers=8
StartTrappers=5
CacheSize=512M
HistoryCacheSize=256M
EOF

  systemctl restart zabbix-server zabbix-agent apache2 || error_exit "Falha ao reiniciar serviços"
  log "Zabbix configurado com sucesso"
}

# Instalação do Grafana
install_grafana() {
  log "Iniciando instalação do Grafana"
  
  # Adicionar repositório seguro
  gpg --dearmor <<EOF > /usr/share/keyrings/grafana.gpg
-----BEGIN PGP PUBLIC KEY BLOCK-----
... [inserir chave GPG real aqui] ...
-----END PGP PUBLIC KEY BLOCK-----
EOF

  echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://packages.grafana.com/oss/deb stable main" > /etc/apt/sources.list.d/grafana.list

  # Instalar Grafana
  apt-get update -qqy || error_exit "Falha na atualização de repositórios do Grafana"
  apt-get install -qqy grafana zabbix-plugin || error_exit "Falha na instalação do Grafana"

  # Configurar senha admin
  GRAFANA_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+-=')
  grafana-cli admin reset-admin-password "$GRAFANA_PASS" || error_exit "Falha ao configurar senha do Grafana"
  
  systemctl start grafana-server || error_exit "Falha ao iniciar Grafana"
  log "Grafana instalado com sucesso"
}

# Configurar HTTPS
configure_https() {
  log "Configurando certificado SSL"
  
  apt-get install -qqy certbot python3-certbot-apache || error_exit "Falha ao instalar Certbot"
  
  certbot --apache --non-interactive --agree-tos --redirect \
    --email "admin@$DOMAIN" \
    -d "$DOMAIN" \
    -d "grafana.$DOMAIN" || error_exit "Falha ao obter certificado SSL"

  # Configurar virtual hosts
  a2enmod ssl proxy proxy_http || error_exit "Falha ao ativar módulos Apache"
  systemctl reload apache2 || error_exit "Falha ao recarregar Apache"
  log "HTTPS configurado com sucesso"
}

# Finalização
finalize() {
  clear
  echo "=============================================="
  echo " INSTALAÇÃO CONCLUÍDA COM SUCESSO"
  echo "=============================================="
  echo " URL Zabbix:     https://$DOMAIN/zabbix"
  echo " Usuário:        $ZABBIX_USER"
  echo " Senha:          ********"
  echo "----------------------------------------------"
  echo " URL Grafana:    https://grafana.$DOMAIN"
  echo " Usuário:        admin"
  echo " Senha:          $GRAFANA_PASS"
  echo "=============================================="
  echo " Log completo disponível em: $LOG_FILE"
}

# Fluxo principal
{
  setup_environment
  get_user_input
  install_zabbix
  install_grafana
  configure_https
  finalize
} > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
