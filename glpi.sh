#!/bin/bash

# Variáveis
DB_NAME="glpi"
DB_USER="glpi_user"
DB_PASS="senha_segura"
GLPI_PATH="/var/www/html/glpi"
APACHE_CONF="/etc/apache2/sites-available/glpi.conf"
LOG_FILE="/var/log/glpi_install.log"
GLPI_URL="https://github.com/glpi-project/glpi/releases/latest/download/glpi.tgz"
GLPI_ARCHIVE="/tmp/glpi.tgz"

# Função para verificar erro
check_error() {
    if [ $? -ne 0 ]; then
        echo "Erro: $1" | tee -a "$LOG_FILE"
        exit 1
    fi
}

# Atualizando o sistema
echo "Atualizando pacotes..."
apt update -y &>> "$LOG_FILE" && apt upgrade -y &>> "$LOG_FILE"
check_error "Falha ao atualizar pacotes."

# Instalando dependências essenciais
echo "Instalando dependências..."
apt install -y apache2 mariadb-server php php-mysql php-curl php-gd php-intl php-xml php-zip php-bz2 php-mbstring php-ldap php-apcu php-cli php-common php-soap php-xmlrpc wget unzip curl &>> "$LOG_FILE"
check_error "Falha ao instalar dependências."

# Configurando banco de dados
echo "Configurando banco de dados..."
mysql -e "DROP DATABASE IF EXISTS $DB_NAME; CREATE DATABASE $DB_NAME;" &>> "$LOG_FILE"
check_error "Falha ao criar banco de dados."

mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost'; CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" &>> "$LOG_FILE"
check_error "Falha ao criar usuário do banco de dados."

mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;" &>> "$LOG_FILE"
check_error "Falha ao conceder privilégios ao usuário do banco de dados."

# Baixando GLPI
echo "Baixando GLPI..."
rm -rf "$GLPI_PATH"
wget -O "$GLPI_ARCHIVE" "$GLPI_URL" &>> "$LOG_FILE"
check_error "Falha ao baixar o GLPI. Verifique sua conexão com a internet."

echo "Extraindo GLPI..."
tar -xzf "$GLPI_ARCHIVE" -C /var/www/html/ &>> "$LOG_FILE"
check_error "Falha ao extrair o GLPI."

mv /var/www/html/glpi-* "$GLPI_PATH"
check_error "Falha ao mover arquivos do GLPI."

# Configurando permissões
echo "Ajustando permissões..."
chown -R www-data:www-data "$GLPI_PATH"
chmod -R 755 "$GLPI_PATH"
check_error "Falha ao configurar permissões."

# Configurando Apache
echo "Configurando Apache..."
cat > "$APACHE_CONF" <<EOF
<VirtualHost *:80>
    DocumentRoot "$GLPI_PATH/public"
    <Directory "$GLPI_PATH/public">
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
EOF

ln -s "$APACHE_CONF" /etc/apache2/sites-enabled/
a2enmod rewrite &>> "$LOG_FILE"
check_error "Falha ao ativar módulo rewrite."

systemctl restart apache2 &>> "$LOG_FILE"
check_error "Falha ao reiniciar Apache."

# Mensagem de conclusão
echo "Instalação concluída com sucesso! Acesse o GLPI via http://seu_servidor" | tee -a "$LOG_FILE"
echo "Usuário padrão para login: glpi" | tee -a "$LOG_FILE"
echo "Senha padrão: glpi" | tee -a "$LOG_FILE"
