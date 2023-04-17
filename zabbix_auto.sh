#!/bin/bash

PASSWORD="zbx#2k23$aut0"

# Definir a senha do root do MySQL
debconf-set-selections <<< "mysql-server mysql-server/root_password password $PASSWORD"
debconf-set-selections <<< "mysql-server mysql-server/root_password_again password $PASSWORD"

# Instalar os pacotes necessários
apt-get update
apt-get install -y apache2 mysql-server mysql-client snmp snmpd libmysqlclient-dev libsnmp-dev libopenipmi-dev libcurl4-gnutls-dev fping libxml2-dev libevent-dev make automake libtool libpcre3-dev libssl-dev libsnmp-dev libcurl4-openssl-dev pkg-config php php-cgi libapache2-mod-php php-common php-pear php-mbstring php-gd php-intl php-mysql php-bcmath php-zip php-xml php-ldap composer

# Definir timezone para São Paulo
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# Adicionar o repositório do Zabbix
wget https://repo.zabbix.com/zabbix/6.2/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.2-1+ubuntu22.04_all.deb
dpkg -i zabbix-release_6.2-1+ubuntu22.04_all.deb
apt-get update

# Instalar o Zabbix server e frontend
apt-get install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf

# Define o idioma padrão do Zabbix para pt-BR
sudo sed -i "s/'language' => 'en_GB'/'language' => 'pt_BR'/g" /usr/share/zabbix/include/classes/core/CWebUser.php

# Criar banco de dados para o Zabbix
mysql -uroot -p$PASSWORD -e "CREATE DATABASE zabbix CHARACTER SET utf8 COLLATE utf8_bin;"
mysql -uroot -p$PASSWORD -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '$PASSWORD';"
mysql -uroot -p$PASSWORD -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';"

# Importar o schema do banco de dados do Zabbix
cd /usr/share/doc/zabbix-server-mysql
gunzip -c create.sql.gz | mysql -uzabbix -p$PASSWORD zabbix

# Habilitar e iniciar o serviço do Zabbix server
systemctl enable zabbix-server
systemctl start zabbix-server

# Configurar o firewall
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 10050/tcp
ufw allow 10051/tcp
ufw enable

# Instalar o Grafana
wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt-get update
sudo apt-get install -y grafana

# Habilitar e iniciar o serviço do Grafana
sudo systemctl enable grafana-server
sudo systemctl start grafana-server

# Instalar o SNMP
apt-get install -y snmp snmpd net-snmp snmp-mibs-downloader

# Reiniciar o Apache
systemctl restart apache2

echo

echo "Script finalizado!"
