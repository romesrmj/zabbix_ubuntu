#!/bin/bash

# Variáveis
ZABBIX_VERSION="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb"
TIMEZONE="America/Sao_Paulo"
LOCALE="pt_BR.UTF-8"
DB_NAME="zabbix_db"
DB_USER="zabbix_user"
GRAFANA_VERSION="https://dl.grafana.com/enterprise/release/grafana-enterprise_9.5.3_amd64.deb"  # Exemplo de URL do Grafana

# Função para remover o Zabbix e Grafana, se existir
remove_existing() {
    echo "Removendo Zabbix e Grafana existentes..."
    systemctl stop zabbix-server zabbix-agent apache2 grafana-server
    apt-get purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent grafana
    apt-get autoremove -y
}

# Verificar se o script está sendo executado como root
if [[ "$EUID" -ne 0 ]]; then
    echo "Por favor, execute este script como root."
    exit 1
fi

# Remover instalação anterior do Zabbix e Grafana, se houver
remove_existing

# Configurar timezone
echo "Configurando timezone..."
timedatectl set-timezone "$TIMEZONE" || { echo "Erro ao definir o timezone"; exit 1; }

# Configurar locale
echo "Configurando locale..."
locale-gen $LOCALE
update-locale LANG=$LOCALE || { echo "Erro ao configurar o locale"; exit 1; }

# Instalar pacotes necessários
echo "Atualizando sistema e instalando pré-requisitos..."
apt update -y
apt install -y wget gnupg2 software-properties-common mysql-server || { echo "Erro ao instalar pacotes necessários"; exit 1; }

# Solicitar a senha do root do MySQL
read -s -p "Insira a senha do root do MySQL: " MYSQL_ROOT_PASSWORD
echo

# Solicitar a senha para o usuário do Zabbix
read -s -p "Insira a senha para o usuário do Zabbix: " ZABBIX_USER_PASSWORD
echo

# Verificar se o banco de dados existe e remover se necessário
DB_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES LIKE '$DB_NAME';" 2>/dev/null)
if [[ -n "$DB_EXIST" ]]; then
    echo "O banco de dados '$DB_NAME' já existe. Removendo..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE $DB_NAME;" || { echo "Erro ao remover o banco de dados"; exit 1; }
fi

# Verificar se o usuário existe e remover se necessário
USER_EXIST=$(mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '$DB_USER');" 2>/dev/null)
if [[ "$USER_EXIST" == *"1"* ]]; then
    echo "O usuário '$DB_USER' já existe. Removendo..."
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP USER '$DB_USER'@'localhost';" || { echo "Erro ao remover o usuário"; exit 1; }
fi

# Criar banco de dados e usuário do Zabbix
echo "Criando banco de dados e usuário do Zabbix..."
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8 COLLATE utf8_bin;" || { echo "Erro ao criar o banco de dados"; exit 1; }
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$ZABBIX_USER_PASSWORD';" || { echo "Erro ao criar o usuário"; exit 1; }
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" || { echo "Erro ao conceder privilégios"; exit 1; }
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;" || { echo "Erro ao atualizar privilégios"; exit 1; }

# Instalar Zabbix
echo "Instalando Zabbix..."
wget "$ZABBIX_VERSION" -O /tmp/zabbix-release.deb || { echo "Erro ao baixar o pacote Zabbix"; exit 1; }
dpkg -i /tmp/zabbix-release.deb || { echo "Erro ao instalar o pacote Zabbix"; exit 1; }
apt update -y
apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent || { echo "Erro ao instalar Zabbix"; exit 1; }

# Verificar se o arquivo SQL existe
ZABBIX_SQL_FILE="/usr/share/doc/zabbix-server-mysql/create.sql.gz"

# Verificação do arquivo SQL
if [ -f "$ZABBIX_SQL_FILE" ]; then
    echo "Arquivo SQL encontrado em: $ZABBIX_SQL_FILE"
else
    echo "Arquivo SQL para Zabbix não encontrado em: $ZABBIX_SQL_FILE"
    echo "Tentando localizar o arquivo SQL em outros diretórios..."
    ZABBIX_SQL_FILE=$(find /usr/share/doc/ -name "create.sql.gz" 2>/dev/null | grep zabbix)

    if [ -n "$ZABBIX_SQL_FILE" ]; then
        echo "Arquivo SQL encontrado em: $ZABBIX_SQL_FILE"
    else
        echo "Arquivo SQL para Zabbix não encontrado. Certifique-se de que o Zabbix foi instalado corretamente."
        exit 1
    fi
fi

# Importar o esquema inicial para o banco de dados Zabbix
echo "Importando esquema inicial para o banco de dados Zabbix..."
zcat "$ZABBIX_SQL_FILE" | mysql -u"$DB_USER" -p"$ZABBIX_USER_PASSWORD" "$DB_NAME" || { echo "Erro ao importar o esquema do banco de dados Zabbix"; exit 1; }

# Atualizar configuração do Zabbix
echo "Atualizando configuração do Zabbix..."
sed -i "s/^DBPassword=.*/DBPassword='$ZABBIX_USER_PASSWORD'/" /etc/zabbix/zabbix_server.conf

# Reiniciar serviços do Zabbix
echo "Reiniciando serviços do Zabbix..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

# Instalar Grafana
echo "Instalando Grafana..."
wget "$GRAFANA_VERSION" -O /tmp/grafana.deb || { echo "Erro ao baixar o pacote Grafana"; exit 1; }
dpkg -i /tmp/grafana.deb || { echo "Erro ao instalar o pacote Grafana"; exit 1; }
apt-get install -f -y || { echo "Erro ao corrigir dependências do Grafana"; exit 1; }

# Reiniciar e habilitar o serviço do Grafana
echo "Reiniciando serviços do Grafana..."
systemctl enable --now grafana-server || { echo "Erro ao habilitar o Grafana"; exit 1; }

# Exibir informações do sistema com Neofetch
echo "Exibindo informações do sistema..."
apt-get install -y neofetch || { echo "Erro ao instalar o Neofetch"; exit 1; }
neofetch

# Finalização
echo "Instalação do Zabbix e Grafana concluída com sucesso."
echo "Acesse o Zabbix na URL: http://<IP_DO_SEU_SERVIDOR>/zabbix"
echo "Acesse o Grafana na URL: http://<IP_DO_SEU_SERVIDOR>:3000"
