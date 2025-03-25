#!/bin/bash

# Verificação de privilégios
if [ "$EUID" -ne 0 ]; then
  echo "Execute como root: sudo ./deploy_zabbix.sh"
  exit 1
fi

# Configurações globais
ZABBIX_CONF="/etc/zabbix/zabbix_server.conf"
LOG_FILE="/var/log/zabbix_deploy.log"
TIMESTAMP=$(date +"%Y-%m-%d %T")

# Funções principais
init_setup() {
  echo "[$TIMESTAMP] Iniciando instalação" > $LOG_FILE
  apt-get update -qq >> $LOG_FILE
}

show_header() {
  clear
  echo "=============================================="
  echo " $1"
  echo "=============================================="
  sleep 2
}

get_credentials() {
  show_header "CONFIGURAÇÃO INICIAL"
  
  while true; do
    read -p "Domínio principal (ex: monitor.example.com): " DOMAIN
    [[ -n "$DOMAIN" ]] && break
    echo "Domínio inválido!"
  done

  while true; do
    read -p "Usuário admin Zabbix: " ZABBIX_USER
    [[ -n "$ZABBIX_USER" ]] && break
    echo "Usuário não pode ser vazio!"
  done

  while true; do
    read -sp "Senha para $ZABBIX_USER: " ZABBIX_PASS
    [[ -n "$ZABBIX_PASS" ]] && break
    echo -e "\nSenha inválida!"
  done
  echo
}

setup_snmp() {
  show_header "ATUALIZANDO SNMP"
  apt-get install -qq -y snmp snmpd snmp-mibs-downloader >> $LOG_FILE
  systemctl restart snmpd >> $LOG_FILE
}

install_zabbix() {
  show_header "INSTALANDO ZABBIX 7.0 LTS"
  
  # Repositório e pacotes
  wget -q https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb
  dpkg -i zabbix-release_latest_7.0+ubuntu24.04_all.deb >> $LOG_FILE
  apt-get update -qq >> $LOG_FILE
  
  # Instalação
  apt-get install -qq -y \
    zabbix-server-mysql \
    zabbix-frontend-php \
    zabbix-apache-conf \
    zabbix-sql-scripts \
    zabbix-agent >> $LOG_FILE

  # Configuração MySQL
  DB_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+-=')
  mysql -e "CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
  mysql -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';"
  zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -u zabbix -p"${DB_PASS}" zabbix >> $LOG_FILE

  # Otimização
  declare -A configs=(
    ["DBHost"]="localhost"
    ["DBPassword"]="$DB_PASS"
    ["StartPollers"]="8"
    ["StartTrappers"]="5"
    ["CacheSize"]="512M"
    ["HistoryCacheSize"]="256M"
  )
  for key in "${!configs[@]}"; do
    sed -i "s/^# $key=.*/$key=${configs[$key]}/" $ZABBIX_CONF
  done

  systemctl restart zabbix-server zabbix-agent apache2 >> $LOG_FILE
}

setup_grafana() {
  show_header "INSTALANDO GRAFANA"
  
  # Repositório
  gpg --dearmor <<EOF > /usr/share/keyrings/grafana.gpg
-----BEGIN PGP PUBLIC KEY BLOCK-----
... [conteúdo real da chave GPG] ...
-----END PGP PUBLIC KEY BLOCK-----
EOF

  echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://packages.grafana.com/oss/deb stable main" > /etc/apt/sources.list.d/grafana.list

  # Instalação
  apt-get update -qq >> $LOG_FILE
  apt-get install -qq -y grafana zabbix-plugin >> $LOG_FILE
  
  # Segurança
  GRAFANA_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+-=')
  grafana-cli admin reset-admin-password "$GRAFANA_PASS" >> $LOG_FILE
  systemctl start grafana-server >> $LOG_FILE
}

setup_https() {
  show_header "CONFIGURANDO HTTPS"
  
  # Certbot
  apt-get install -qq -y certbot python3-certbot-apache >> $LOG_FILE
  certbot --apache --non-interactive --agree-tos --redirect \
    --email "admin@$DOMAIN" \
    -d "$DOMAIN" \
    -d "grafana.$DOMAIN" >> $LOG_FILE

  # Firewall
  ufw allow "Apache Full" >> $LOG_FILE
  ufw reload >> $LOG_FILE
}

finalize() {
  show_header "FINALIZANDO"
  
  # Permissões
  chown -R zabbix:zabbix /etc/zabbix
  chmod 640 $ZABBIX_CONF

  # Relatórios
  echo -e "\n\n✅ INSTALAÇÃO COMPLETA"
  echo "=============================================="
  echo "🌐 Zabbix: https://$DOMAIN/zabbix"
  echo "👤 Usuário: $ZABBIX_USER"
  echo "🔑 Senha: ********"
  echo "----------------------------------------------"
  echo "📊 Grafana: https://grafana.$DOMAIN"
  echo "👤 Usuário: admin"
  echo "🔑 Senha: $GRAFANA_PASS"
  echo "=============================================="
  echo "🔍 Log completo: tail -f $LOG_FILE"
}

# Fluxo principal
init_setup
get_credentials
setup_snmp
install_zabbix
setup_grafana
setup_https
finalize
