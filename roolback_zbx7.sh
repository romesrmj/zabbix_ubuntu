#!/bin/bash

# ==============================
#  ROLLBACK ZABBIX + GRAFANA + MARIADB
#  PARA UBUNTU 22.04
# ==============================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Execute como root: sudo $0"
    exit 1
fi

read -p "🧑‍💼 Informe o usuário do banco Zabbix a ser removido: " DB_USER

echo "🛑 Parando serviços..."
systemctl stop zabbix-server zabbix-agent2 apache2 grafana-server || true

echo "🗑 Removendo pacotes..."
apt remove --purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent2 apache2 grafana mariadb-server || true
apt autoremove -y
apt autoclean -y

echo "🗑 Removendo banco de dados Zabbix e usuário..."
mysql -uroot -e "DROP DATABASE IF EXISTS zabbix;" || true
mysql -uroot -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" || true

echo "🗑 Removendo repositórios e arquivos temporários..."
rm -f /etc/apt/sources.list.d/grafana.list
rm -f /usr/share/keyrings/grafana.gpg
rm -f /etc/apt/sources.list.d/zabbix-release_*.list || true

echo "✅ Rollback concluído. O sistema voltou ao estado anterior."
