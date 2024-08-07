#!/bin/bash

# Atualizar pacotes
sudo apt update && sudo apt upgrade -y

# Instalar dependências
sudo apt install -y apache2 mysql-server php php-mysql php-gd php-xml php-bcmath php-mbstring php-ldap php-json php-xmlrpc wget

# Gerar senha aleatória para o banco de dados
DB_PASSWORD=$(openssl rand -base64 12)

# Criar banco de dados e usuário para o Zabbix
sudo mysql -e "CREATE DATABASE zabbix character set utf8 collate utf8_bin;"
sudo mysql -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
sudo mysql -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Instalar Zabbix
wget https://repo.zabbix.com/zabbix/6.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.0-1+ubuntu20.04_all.deb
sudo dpkg -i zabbix-release_6.0-1+ubuntu20.04_all.deb
sudo apt update
sudo apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-agent

# Importar esquema inicial para o banco de dados Zabbix
zcat /usr/share/doc/zabbix-server-mysql*/create.sql.gz | mysql -uzabbix -p$DB_PASSWORD zabbix

# Configurar Zabbix para usar o banco de dados e ajustar timezone
sudo sed -i "s/# DBPassword=/DBPassword=$DB_PASSWORD/" /etc/zabbix/zabbix_server.conf

# Ajustar timezone para São Paulo no Zabbix
sudo sed -i 's/# php_value date.timezone Europe\/Riga/php_value date.timezone America\/Sao_Paulo/' /etc/zabbix/apache.conf

# Reiniciar serviços
sudo systemctl restart zabbix-server zabbix-agent apache2
sudo systemctl enable zabbix-server zabbix-agent apache2

# Instalar Grafana
wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt update
sudo apt install -y grafana
sudo systemctl start grafana-server
sudo systemctl enable grafana-server

# Instalar plugin do Grafana (exemplo com o plugin Zabbix)
sudo grafana-cli plugins install alexanderzobnin-zabbix-app

# Reiniciar Grafana para ativar o plugin
sudo systemctl restart grafana-server

# Criar diretório para a configuração do Grafana
sudo mkdir -p /etc/grafana/provisioning/datasources

# Criar arquivo de configuração do data source do Zabbix
cat << EOF | sudo tee /etc/grafana/provisioning/datasources/zabbix.yml
apiVersion: 1
datasources:
  - name: Zabbix
    type: alexanderzobnin-zabbix-datasource
    access: proxy
    url: http://localhost/zabbix
    isDefault: true
    jsonData:
      username: Admin
      password: zabbix
EOF

# Reiniciar Grafana para aplicar a configuração
sudo systemctl restart grafana-server

# Criar arquivo Markdown com a senha do banco de dados
echo "# Zabbix & Grafana Setup" > zabbix_grafana_credentials.md
echo "## Zabbix Database Credentials" >> zabbix_grafana_credentials.md
echo "- **Database User**: zabbix" >> zabbix_grafana_credentials.md
echo "- **Database Password**: $DB_PASSWORD" >> zabbix_grafana_credentials.md

# Mostrar senha no terminal
cat zabbix_grafana_credentials.md

echo "Setup concluído. Verifique o arquivo zabbix_grafana_credentials.md para as credenciais do banco de dados."
