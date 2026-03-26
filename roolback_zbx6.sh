#!/bin/bash

# ============================================================
# ROLLBACK COMPLETO — ZABBIX + GRAFANA + MARIADB + APACHE
# Ubuntu 22.04 LTS
# Remove TUDO que foi instalado ou tentado instalar,
# incluindo repositórios, arquivos residuais e configurações.
# ============================================================

set -uo pipefail

LOG_FILE="/var/log/zabbix-rollback.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo "  ROLLBACK — Início: $(date)"
echo "============================================================"

# ============================================================
# Verificação de root
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Execute como root: sudo $0"
    exit 1
fi

# ============================================================
# Confirmação obrigatória
# ============================================================
echo ""
echo "⚠️  ATENÇÃO: Este script irá remover PERMANENTEMENTE:"
echo ""
echo "   • Zabbix Server, Frontend, Agent, SQL Scripts"
echo "   • Grafana e plugin Zabbix"
echo "   • Apache2"
echo "   • MariaDB e todos os bancos de dados"
echo "   • PHP e extensões relacionadas"
echo "   • SNMP e MIBs"
echo "   • Todos os repositórios adicionados"
echo "   • Todos os arquivos de configuração e logs"
echo ""
echo "   ❌ Esta ação NÃO pode ser desfeita!"
echo ""
read -p "   Digite CONFIRMAR para prosseguir: " CONFIRM

if [ "$CONFIRM" != "CONFIRMAR" ]; then
    echo "❌ Rollback cancelado."
    exit 1
fi

echo ""
echo "🔄 Iniciando rollback completo..."

# ============================================================
# Função auxiliar — remove pacote sem parar em erro
# ============================================================
purge_pkg() {
    for pkg in "$@"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^[iuph]"; then
            echo "   Removendo: $pkg"
            DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y "$pkg" 2>/dev/null || true
            dpkg --purge --force-all "$pkg" 2>/dev/null || true
        fi
    done
}

# ============================================================
# 1. Parar todos os serviços
# ============================================================
echo ""
echo "⏹  Parando serviços..."

for svc in zabbix-server zabbix-agent grafana-server apache2 mariadb mysql; do
    if systemctl list-units --full -all 2>/dev/null | grep -q "${svc}.service"; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        echo "   Parado: $svc"
    fi
done

# ============================================================
# 2. Remover Zabbix
# ============================================================
echo ""
echo "🗑  Removendo Zabbix..."

purge_pkg \
    zabbix-server-mysql \
    zabbix-frontend-php \
    zabbix-apache-conf \
    zabbix-sql-scripts \
    zabbix-agent \
    zabbix-agent2 \
    zabbix-release \
    zabbix-get \
    zabbix-sender

# ============================================================
# 3. Remover Grafana e plugin
# ============================================================
echo ""
echo "🗑  Removendo Grafana..."

# Remove plugin antes do pacote
if command -v grafana-cli &>/dev/null; then
    grafana-cli plugins remove alexanderzobnin-zabbix-app 2>/dev/null || true
fi

purge_pkg grafana grafana-enterprise

# ============================================================
# 4. Remover Apache2 e PHP
# ============================================================
echo ""
echo "🗑  Removendo Apache2 e PHP..."

purge_pkg \
    apache2 \
    apache2-bin \
    apache2-data \
    apache2-utils \
    libapache2-mod-php \
    libapache2-mod-php8.1

# Remove todos os pacotes PHP instalados
PHP_PKGS=$(dpkg -l | grep -E "^ii\s+php" | awk '{print $2}' | tr '\n' ' ')
if [ -n "$PHP_PKGS" ]; then
    echo "   Removendo pacotes PHP: $PHP_PKGS"
    DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y $PHP_PKGS 2>/dev/null || true
fi

# ============================================================
# 5. Remover MariaDB / MySQL
# ============================================================
echo ""
echo "🗑  Removendo MariaDB / MySQL..."

purge_pkg \
    mariadb-server \
    mariadb-server-core-10.6 \
    mariadb-client \
    mariadb-client-core-10.6 \
    mariadb-common \
    mysql-server \
    mysql-server-8.0 \
    mysql-server-core-8.0 \
    mysql-client \
    mysql-client-8.0 \
    mysql-client-core-8.0 \
    mysql-common \
    libmysqlclient21 \
    libmariadb3

# ============================================================
# 6. Remover SNMP
# ============================================================
echo ""
echo "🗑  Removendo SNMP..."

purge_pkg \
    snmp \
    snmpd \
    snmp-mibs-downloader \
    libsnmp-dev \
    libsnmp40

# Restaura snmp.conf se necessário
if [ -f /etc/snmp/snmp.conf ]; then
    sed -i 's/^# mibs :/mibs :/' /etc/snmp/snmp.conf 2>/dev/null || true
fi

# ============================================================
# 7. Remover pacotes auxiliares instalados pelo script
# ============================================================
echo ""
echo "🗑  Removendo pacotes auxiliares..."

purge_pkg \
    gnupg2 \
    apt-transport-https \
    software-properties-common \
    snmp-mibs-downloader

# ============================================================
# 8. Limpeza de arquivos e diretórios
# ============================================================
echo ""
echo "🧹 Removendo arquivos residuais..."

# Zabbix
rm -rf /etc/zabbix
rm -rf /var/lib/zabbix
rm -rf /var/log/zabbix
rm -rf /usr/share/zabbix
rm -rf /usr/share/zabbix-sql-scripts
rm -rf /usr/share/doc/zabbix-*
rm -rf /run/zabbix

# Grafana
rm -rf /etc/grafana
rm -rf /var/lib/grafana
rm -rf /var/log/grafana
rm -rf /usr/share/grafana
rm -rf /var/lib/grafana/plugins/alexanderzobnin-zabbix-app

# Apache2
rm -rf /etc/apache2
rm -rf /var/log/apache2
rm -rf /var/www/html/zabbix
rm -rf /usr/share/doc/apache2*

# MariaDB / MySQL
rm -rf /var/lib/mysql
rm -rf /var/lib/mariadb
rm -rf /etc/mysql
rm -rf /var/log/mysql
rm -rf /var/log/mariadb
rm -rf /run/mysqld
rm -rf /run/mariadb

# PHP
rm -rf /etc/php
rm -rf /usr/lib/php

# SNMP
rm -rf /var/lib/snmp
rm -rf /usr/share/snmp/mibs

# ============================================================
# 9. Remover repositórios adicionados
# ============================================================
echo ""
echo "🗂  Removendo repositórios..."

rm -f /etc/apt/sources.list.d/zabbix.list
rm -f /etc/apt/sources.list.d/grafana.list
rm -f /usr/share/keyrings/grafana.gpg
rm -f /usr/share/keyrings/zabbix*.gpg
rm -f /etc/apt/trusted.gpg.d/zabbix*.gpg

# Limpa arquivos .deb temporários que possam ter ficado
rm -f /tmp/zabbix-release*.deb
rm -f /tmp/grafana*.deb

# ============================================================
# 10. Remover usuários e grupos criados
# ============================================================
echo ""
echo "👤 Removendo usuários e grupos de sistema..."

for user in zabbix grafana mysql mariadb www-data; do
    if id "$user" &>/dev/null; then
        userdel -r "$user" 2>/dev/null || true
        echo "   Usuário removido: $user"
    fi
done

for group in zabbix grafana mysql mariadb www-data; do
    if getent group "$group" &>/dev/null; then
        groupdel "$group" 2>/dev/null || true
        echo "   Grupo removido: $group"
    fi
done

# ============================================================
# 11. Remover units systemd residuais
# ============================================================
echo ""
echo "⚙️  Limpando units systemd..."

for unit in zabbix-server zabbix-agent zabbix-agent2 grafana-server apache2 mariadb mysql; do
    rm -f "/etc/systemd/system/${unit}.service"
    rm -f "/usr/lib/systemd/system/${unit}.service"
    rm -f "/lib/systemd/system/${unit}.service"
done

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

# ============================================================
# 12. apt autoremove e limpeza geral
# ============================================================
echo ""
echo "🧹 Limpeza final do apt..."

apt-get autoremove --purge -y 2>/dev/null || true
apt-get autoclean -y 2>/dev/null || true
apt-get update -qq 2>/dev/null || true

# ============================================================
# 13. Verificação final
# ============================================================
echo ""
echo "🔍 Verificação final..."

RESIDUAL=false

for pkg in zabbix-server-mysql zabbix-frontend-php zabbix-agent \
           grafana apache2 mariadb-server mysql-server; do
    STATUS=$(dpkg -l "$pkg" 2>/dev/null | grep "^ii" || true)
    if [ -n "$STATUS" ]; then
        echo "   ⚠️  Ainda instalado: $pkg"
        RESIDUAL=true
    fi
done

for dir in /etc/zabbix /var/lib/mysql /etc/grafana /etc/apache2 /etc/mysql; do
    if [ -d "$dir" ]; then
        echo "   ⚠️  Diretório residual: $dir"
        RESIDUAL=true
    fi
done

echo ""
if [ "$RESIDUAL" = false ]; then
    echo "============================================================"
    echo "  ✅ ROLLBACK CONCLUÍDO — Sistema limpo!"
    echo "  $(date '+%d/%m/%Y %H:%M:%S')"
    echo "============================================================"
    echo "  O sistema está como antes da instalação do Zabbix/Grafana."
    echo "  Log deste rollback: ${LOG_FILE}"
    echo "============================================================"
else
    echo "============================================================"
    echo "  ⚠️  ROLLBACK CONCLUÍDO COM ALERTAS"
    echo "  Alguns itens acima podem precisar de remoção manual."
    echo "  Log deste rollback: ${LOG_FILE}"
    echo "============================================================"
fi
