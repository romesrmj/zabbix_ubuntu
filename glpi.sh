#!/bin/bash

# Diretório onde o GLPI será instalado
GLPI_DIR="/var/www/html/glpi"

# URL do GLPI 10
GLPI_URL="https://github.com/glpi-project/glpi/releases/download/10.0.0/glpi-10.0.0.tgz"

# Configurações do banco de dados
DB_NAME="glpi"
DB_USER="glpi_user"
DB_PASS="senha_segura"

# Instalar dependências
sudo apt-get update
sudo apt-get install -y apache2 mysql-server php libapache2-mod-php php-mysql php-curl php-gd php-intl php-json php-mbstring php-xml php-zip wget

# Criar diretório do GLPI
mkdir -p $GLPI_DIR
cd $GLPI_DIR

# Baixar e extrair o GLPI
wget $GLPI_URL -O glpi.tgz
tar -xvzf glpi.tgz --strip-components=1 -C $GLPI_DIR

# Configurar permissões
chown -R www-data:www-data $GLPI_DIR
chmod -R 755 $GLPI_DIR

# Configurar banco de dados
sudo mysql -e "CREATE DATABASE $DB_NAME;"
sudo mysql -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Reiniciar Apache
sudo systemctl restart apache2

echo "Instalação do GLPI 10 concluída! Acesse http://seu-servidor/glpi"
