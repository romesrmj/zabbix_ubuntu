#!/bin/bash

# Verificação de pré-requisitos e permissões
if [[ "$EUID" -ne 0 ]]; then
    echo "Por favor, execute este script como root."
    exit 1
fi

# Função para criar uma senha aleatória
generate_password() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 12
}

# Solicitar a senha do root do MySQL
read -s -p "Insira a senha do root do MySQL: " MYSQL_ROOT_PASSWORD
echo

# Parâmetros de configuração
DB_NAME="zabbix_db"
DB_USER="zabbix_user"
DB_PASSWORD=$(generate_password)  # Senha do Zabbix
GRAFANA_USER="admin"
GRAFANA_PASSWORD=$(generate_password)  # Senha do Grafana

# Função para remover instalações prévias do Zabbix e Grafana
remove_existing_installations() {
    echo "Removendo pacotes anteriores do Zabbix e Grafana..."
    apt-get -y purge zabbix-* grafana*
    apt-get -y autoremove
    rm -rf /etc/zabbix /var/lib/zabbix /etc/grafana /var/lib/grafana
}

# Remover instalações anteriores
remove_existing_installations

# Instalar dependências
apt-get update
apt-get install -y gnupg2 wget neofetch mysql-server

# Instalar Zabbix Server e Frontend
wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_7.0-1+ubuntu24.04_all.deb
dpkg -i zabbix-release_7.0-1+ubuntu24.04_all.deb
apt-get update
apt-get install -y zabbix-server-mysql zabbix-frontend-php zabbix-nginx-conf zabbix-agent

# Configuração do banco de dados MySQL para Zabbix
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS ${DB_NAME};"
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';"
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;"

# Importar esquema inicial do Zabbix
zcat /usr/share/doc/zabbix-server-mysql*/create.sql.gz | mysql -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}"

# Configuração do Zabbix Server
sed -i "s/# DBHost=localhost/DBHost=localhost/" /etc/zabbix/zabbix_server.conf
sed -i "s/# DBPassword=/DBPassword=${DB_PASSWORD}/" /etc/zabbix/zabbix_server.conf

# Iniciar serviços do Zabbix
systemctl enable --now zabbix-server zabbix-agent nginx php-fpm

# Instalação do Grafana
wget https://dl.grafana.com/oss/release/grafana_8.5.9_amd64.deb
dpkg -i grafana_8.5.9_amd64.deb
systemctl enable --now grafana-server

# Configurar Grafana com o Zabbix como fonte de dados
grafana-cli admin reset-admin-password "${GRAFANA_PASSWORD}"
cat <<EOL > /etc/grafana/provisioning/datasources/zabbix.yml
apiVersion: 1
datasources:
  - name: Zabbix
    type: alexanderzobnin-zabbix-datasource
    url: http://localhost/zabbix
    access: proxy
    basicAuth: true
    basicAuthUser: ${DB_USER}
    basicAuthPassword: ${DB_PASSWORD}
EOL

# Restart Grafana para aplicar a configuração do datasource
systemctl restart grafana-server

# Exibir as informações de acesso
clear
neofetch
echo -e "\n*** INFORMAÇÕES DE ACESSO ***"
echo -e "\nZabbix Web URL: http://<host_ip>/zabbix"
echo -e "Usuário do banco de dados Zabbix: ${DB_USER}"
echo -e "Senha do banco de dados Zabbix: ${DB_PASSWORD}\n"
echo -e "Grafana Web URL: http://<host_ip>:3000"
echo -e "Usuário Grafana: ${GRAFANA_USER}"
echo -e "Senha Grafana: ${GRAFANA_PASSWORD}\n"
echo -e "Para mais informações sobre o status do sistema, use 'neofetch'"
