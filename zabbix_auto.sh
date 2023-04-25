#!/bin/bash

#SENHA:zbx#2k23aut0

# Define a senha do root do MySQL
MYSQL_ROOT_PASSWORD="zbx#2k23aut0"

# Define a senha do usuário admin do Zabbix
ZABBIX_ADMIN_PASSWORD="zbx#2k23aut0"

# Define a senha do usuário do Grafana
GRAFANA_USER_PASSWORD="zbx#2k23aut0"

# Define a timezone padrão para America/Sao_Paulo
TIMEZONE="America/Sao_Paulo"

# Define as portas a serem liberadas no firewall
FIREWALL_PORTS=("80" "443" "3000" "10050" "10051")

# Atualiza o sistema
sudo apt-get update -y && sudo apt-get upgrade -y

# Instalando DBConfi
sudo apt-get install debconf
sudo apt-get update -y

# Instala o MySQL e define a senha do root
sudo apt-get install -y zabbix-server-mysql
sudo debconf-set-selections <<< "zabbix-server-mysql zabbix-server-mysql/root_password password $MYSQL_ROOT_PASSWORD"
sudo debconf-set-selections <<< "zabbix-server-mysql zabbix-server-mysql/root_password_again password $MYSQL_ROOT_PASSWORD"
sudo service mysql start

# Instala as dependências do Zabbix
sudo apt-get install -y apache2 php libapache2-mod-php php-mysql php-gd php-bcmath php-xml php-mbstring snmp snmpd snmp-mibs-downloader net-tools locales linux-headers-generic build-essential module-assistant software-properties-common nano needrestart 

# Define o timezone para America/Sao_Paulo
sudo ln -fs /usr/share/zoneinfo/$TIMEZONE /etc/localtime
sudo dpkg-reconfigure --frontend noninteractive tzdata

# Define o locale-gen para pt_BR.UTF-8
locale-gen pt_BR.UTF-8 
m-a prepare 
update-locale LANG=pt_BR.UTF-8 

# REPOSITORIO
wget https://repo.zabbix.com/zabbix/6.4/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.4-1+ubuntu22.04_all.deb
dpkg -i zabbix-release_6.4-1+ubuntu22.04_all.deb
sudo apt-get update -y

# Adiciona o repositório do Grafana
wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list

# Atualiza a lista de pacotes
sudo apt-get update -y

# INSTALL SERVIDOR
apt install zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent

#CRIANDO BANCO DE DADOS
mysql -uroot --password="$MYSQL_ROOT_PASSWORD" -e "create database zabbix character set utf8mb4 collate utf8mb4_bin;"
mysql -uroot --password="$MYSQL_ROOT_PASSWORD" -e "create user 'zabbix'@'localhost' identified by '$ZABBIX_ADMIN_PASSWORD';"
mysql -uroot --password="$MYSQL_ROOT_PASSWORD" -e "grant all privileges on zabbix.* to zabbix@localhost;"
mysql -uroot --password="$MYSQL_ROOT_PASSWORD" -e "set global log_bin_trust_function_creators = 1;"
quit

#SCHEMAS BANCO
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -u zabbix --password="$ZABBIX_ADMIN_PASSWORD" zabbix

#DISABLE LOG_BIN_TRUST
mysql -uroot --password="$MYSQL_ROOT_PASSWORD" -e "set global log_bin_trust_function_creators = 0;"
quit

# EDIT CAMINHO /etc/zabbix/zabbix_server.conf
sudo sed -i 's/# DBPassword=' /'DBPassword="$ZABBIX_ADMIN_PASSWORD"/g" /etc/zabbix/zabbix_server.conf
#sudo sed -i "s/^.DBPassword=.$/DBPassword="$ZABBIX_ADMIN_PASSWORD"/g" /etc/zabbix/zabbix_server.conf
sudo sed -i 's/# php_value date.timezone Europe\/Riga/php_value date.timezone America\/Sao_Paulo/g' /etc/apache2/conf-enabled/zabbix.conf

#FIX CACHESIZE
sed s/'# CacheSize=8M'/'CacheSize=16M'/g -i /etc/zabbix/zabbix_server.conf

/etc/init.d/zabbix-server restart

#Reinicia o serviço do Zabbix server e do Apache
sudo systemctl restart zabbix-server zabbix-agent apache2

#Habilita os serviços do Zabbix server e do Apache para iniciar automaticamente no boot
sudo systemctl enable zabbix-server zabbix-agent apache2

#Instala o Grafana
sudo apt-get install -y grafana

#Inicia o serviço do Grafana
sudo systemctl start grafana-server

#Habilita o serviço do Grafana para iniciar automaticamente no boot
sudo systemctl enable grafana-server

#Instala o plugin do Zabbix no Grafana
sudo grafana-cli plugins install alexanderzobnin-zabbix-app
sudo grafana-cli plugins update alexanderzobnin-zabbix-app

#Reinicia o serviço do Grafana
sudo systemctl restart grafana-server

clear

#Imprime as informações de acesso
echo "Zabbix URL: http://$(curl -s ifconfig.co):8080/zabbix"
echo "Grafana URL: http://$(curl -s ifconfig.co):3000"
echo "Zabbix Admin Username: Admin"
echo "Zabbix Admin Password: $ZABBIX_ADMIN_PASSWORD"
echo "Grafana Admin Username: admin"
echo "Grafana Admin Password: admin"

echo "Script finalizado!"
