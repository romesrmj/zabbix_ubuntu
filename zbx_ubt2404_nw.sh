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

# Verificar e limpar instalação anterior do MySQL
clean_mysql_legacy() {
  log "Verificando instalações anteriores do Zabbix"
  
  if mysql -e "SELECT 1" &>/dev/null; then
    log "Removendo usuário e database existentes"
    
    # Remover usuário se existir
    mysql -e "DROP USER IF EXISTS 'zabbix'@'localhost'" || :
    
    # Remover database se existir
    mysql -e "DROP DATABASE IF EXISTS zabbix" || :
    
    # Limpar privilégios
    mysql -e "FLUSH PRIVILEGES" || error_exit "Falha ao atualizar privilégios"
  fi
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
  
  clean_mysql_legacy
  
  log "Criando novos recursos do banco de dados"
  mysql -e "CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;" || error_exit "Falha ao criar banco de dados"
  mysql -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '${DB_PASS}';" || error_exit "Falha ao criar usuário do banco"
  mysql -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';" || error_exit "Falha ao conceder privilégios"
  mysql -e "FLUSH PRIVILEGES" || error_exit "Falha ao atualizar privilégios"
  
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

# ... [As funções install_grafana, configure_https e finalize permanecem iguais] ...

# Fluxo principal
{
  setup_environment
  get_user_input
  install_zabbix
  install_grafana
  configure_https
  finalize
} > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
