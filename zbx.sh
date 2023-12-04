#!/bin/bash

# Define a senha padrão
SENHA_PADRAO="99999999"

# Atualiza o sistema
echo "Atualizando o sistema..."
apt update
apt upgrade -y

# Adiciona repositório Zabbix
echo "Adicionando repositório Zabbix..."
wget https://repo.zabbix.com/zabbix/6.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.0-1+ubuntu22.04_all.deb
dpkg -i zabbix-release_6.0-1+ubuntu22.04_all.deb
apt update

# Instalação do Zabbix Server, Frontend e Agent
echo "Instalando Zabbix Server, Frontend e Agent..."
DEBIAN_FRONTEND=noninteractive apt-get install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent mysql-server

# Configuração do MySQL para o Zabbix
echo "Configurando MySQL para Zabbix..."
mysql -u root -p$SENHA_PADRAO -e "CREATE DATABASE zabbix character set utf8 collate utf8_bin;"
mysql -u root -p$SENHA_PADRAO -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY 'sua_senha_zabbix';"
mysql -u root -p$SENHA_PADRAO -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost' WITH GRANT OPTION;"
zcat /usr/share/doc/zabbix-server-mysql*/create.sql.gz | mysql -uzabbix -p$SENHA_PADRAO zabbix

# Configuração do Zabbix Server
echo "Configurando Zabbix Server..."
echo "DBPassword=$SENHA_PADRAO" >> /etc/zabbix/zabbix_server.conf
echo "ServerTimeZone=America/Sao_Paulo" >> /etc/zabbix/zabbix_server.conf
echo "DefaultCharset=UTF-8" >> /etc/zabbix/zabbix_server.conf
echo "Include=/etc/zabbix/zabbix_server.conf.d/*.conf" >> /etc/zabbix/zabbix_server.conf

# Reinicia serviços do Zabbix
systemctl restart zabbix-server zabbix-agent apache2

# Instalação do Grafana com plugin do Zabbix
echo "Instalando Grafana com plugin do Zabbix..."
wget https://dl.grafana.com/oss/release/grafana_8.0.6_amd64.deb
dpkg -i grafana_8.0.6_amd64.deb
systemctl enable --now grafana-server
grafana-cli plugins install alexanderzobnin-zabbix-app

# Reinicia o serviço Grafana
systemctl restart grafana-server

echo "Instalação e configuração concluídas. Acesse o Zabbix frontend em http://seu_servidor/zabbix e o Grafana em http://seu_servidor:3000"
