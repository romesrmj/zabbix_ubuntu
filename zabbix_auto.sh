#!/bin/bash

# Define a timezone para São Paulo
echo "Configurando timezone..."
sudo timedatectl set-timezone America/Sao_Paulo

# Atualiza o sistema
echo "Atualizando o sistema..."
sudo apt update -y && sudo apt upgrade -y

# Instala o Apache, PHP, MySQL e outras ferramentas necessárias
echo "Instalando Apache, PHP, MySQL e outras ferramentas necessárias..."
sudo apt install -y apache2 php libapache2-mod-php mysql-server mysql-client php-mysql php-gd php-xml php-bcmath php-mbstring php-ldap php-xmlrpc php-soap net-tools snmp

# Altera a senha do root do MySQL
echo "Alterando a senha do root do MySQL..."
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY 'zbx#2k23$aut0'; FLUSH PRIVILEGES;"

# Adiciona o repositório do Zabbix
echo "Adicionando o repositório do Zabbix..."
wget https://repo.zabbix.com/zabbix/6.4/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.4-1+ubuntu22.04_all.deb
sudo dpkg -i zabbix-release_6.4-1+ubuntu22.04_all.deb

# Instala o Zabbix Server e o Frontend
echo "Instalando o Zabbix Server e o Frontend..."
sudo apt update -y && sudo apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent

# Importa o banco de dados inicial do Zabbix
echo "Importando o banco de dados inicial do Zabbix..."
sudo mysql -uroot -pzbx#2k23$aut0 zabbix < /usr/share/doc/zabbix-server-mysql*/create.sql.gz

# Configura o Zabbix Server
echo "Configurando o Zabbix Server..."
sudo sed -i "s/^DBPassword=.*/DBPassword=zbx#2k23$aut0/" /etc/zabbix/zabbix_server.conf
sudo systemctl restart zabbix-server zabbix-agent apache2

# Adiciona o repositório do Grafana
echo "Adicionando o repositório do Grafana..."
wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list

# Instala o Grafana
echo "Instalando o Grafana..."
sudo apt update -y && sudo apt install -y grafana

# Configura o Grafana
echo "Configurando o Grafana..."
sudo systemctl daemon-reload
sudo systemctl start grafana-server
sudo systemctl enable grafana-server

# Configura o Zabbix Plugin para Grafana
echo "Configurando o Zabbix Plugin para Grafana..."
sudo grafana-cli plugins install alexanderzobnin-zabbix-app
sudo systemctl restart grafana-server

echo "Script finalizado!"
