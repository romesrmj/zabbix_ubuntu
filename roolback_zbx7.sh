#!/bin/bash

# ==============================
#  ROLLBACK ZABBIX 7.0 + APACHE + GRAFANA
#  PARA UBUNTU 24.04 LTS
# ==============================

if [ "$EUID" -ne 0 ]; then
    echo "⚠️ Execute como root: sudo ./rollback_zabbix_ubuntu_24_04.sh"
    exit 1
fi

echo "🛠 Iniciando rollback do Zabbix + Grafana..."

# ==============================
# Para serviços
# ==============================
echo "🚫 Parando serviços..."
systemctl stop zabbix-server zabbix-agent apache2 grafana-server

# ==============================
# Remove pacotes
# ==============================
echo "📦 Removendo pacotes Zabbix e Grafana..."
apt remove --purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent grafana apache2
apt autoremove -y
apt autoclean -y

# ==============================
# Remove repositórios adicionados
# ==============================
echo "🗑 Removendo repositórios Zabbix e Grafana..."
rm -f /etc/apt/sources.list.d/zabbix.list
rm -f /etc/apt/sources.list.d/grafana.list
rm -f /usr/share/keyrings/grafana.gpg
apt update

# ==============================
# Remove banco de dados e usuário do Zabbix
# ==============================
echo "💾 Removendo banco de dados e usuário do Zabbix..."
read -p "🧑‍💼 Informe o nome do usuário do banco que foi criado (ex: zabbix): " DB_USER
read -s -p "🔑 Informe a senha do usuário root do MariaDB/MySQL: " ROOT_PASS
echo ""

mysql -uroot -p${ROOT_PASS} <<EOF
DROP DATABASE IF EXISTS zabbix;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# ==============================
# Remove arquivos de configuração do Zabbix
# ==============================
echo "🗑 Removendo arquivos de configuração do Zabbix..."
rm -rf /etc/zabbix
rm -rf /usr/share/zabbix

# ==============================
# Remove arquivos do Grafana
# ==============================
echo "🗑 Removendo arquivos de configuração do Grafana..."
rm -rf /etc/grafana
rm -rf /var/lib/grafana
rm -rf /var/log/grafana

# ==============================
# Mensagem final
# ==============================
echo ""
echo "✅ Rollback concluído! Todos os pacotes, bancos e arquivos do Zabbix e Grafana foram removidos."
