#!/bin/bash

# Atualiza o sistema
sudo apt update && sudo apt upgrade -y

# Instala os pacotes necessários para o Zabbix
sudo apt install -y apache2 mysql-server php php-mysql php-gd php-xml php-bcmath php-mbstring php-ldap php-xmlrpc libapache2-mod-php

# Cria o banco de dados do Zabbix
sudo mysql -u root -p -e "CREATE DATABASE zabbixdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -u root -p -e "CREATE USER 'zabbixuser'@'localhost' IDENTIFIED WITH mysql_native_password BY 'zbx#2k23$aut0';"
sudo mysql -u root -p -e "GRANT ALL PRIVILEGES ON zabbixdb.* TO 'zabbixuser'@'localhost';"
sudo mysql -u root -p -e "FLUSH PRIVILEGES;"

# Baixa e instala o pacote do Zabbix
wget https://repo.zabbix.com/zabbix/5.4/ubuntu/pool/main/z/zabbix-release/zabbix-release_5.4-1+ubuntu22.04_all.deb
sudo dpkg -i zabbix-release_5.4-1+ubuntu22.04_all.deb
sudo apt update

# Instala o Zabbix Server, Zabbix Frontend e Zabbix Agent
sudo apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent

# Edita o arquivo de configuração do Zabbix Server
sudo sed -i "s/^DBName=.*$/DBName=zabbixdb/" /etc/zabbix/zabbix_server.conf
sudo sed -i "s/^DBUser=.*$/DBUser=zabbixuser/" /etc/zabbix/zabbix_server.conf
sudo sed -i "s/^DBPassword=.*$/DBPassword=zbx#2k23$aut0/" /etc/zabbix/zabbix_server.conf

# Reinicia o serviço do Zabbix Server e ativa-o para inicialização automática
sudo systemctl restart zabbix-server zabbix-agent apache2
sudo systemctl enable zabbix-server zabbix-agent apache2

# Adiciona o repositório do Grafana
wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list

# Instala o Grafana
sudo apt update
sudo apt install -y grafana

# Configura o Grafana para se comunicar com o Zabbix
sudo grafana-cli plugins install alexanderzobnin-zabbix-app
sudo grafana-cli admin reset-admin-password zbx#2k23$aut0
sudo systemctl restart grafana-server

# Abre o firewall para o Grafana
sudo ufw allow 3000/tcp

# Fim do script
