#!/bin/bash

set -e  # Parar o script na primeira ocorrência de erro

# Função para remover Zabbix e Grafana, se existente
remove_existing() {
    echo "Removendo instalações anteriores de Zabbix e Grafana..."
    systemctl stop zabbix-server zabbix-agent apache2 grafana-server || true
    apt-get purge -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent grafana nano > /dev/null 2>&1 || true
    apt-get autoremove -y > /dev/null 2>&1 || true
}

clear

# Verificar e instalar o toilet
if ! command -v toilet &> /dev/null; then
    echo "Instalando o toilet para exibir mensagens..."
    apt update -y > /dev/null 2>&1
    apt install -y toilet > /dev/null 2>&1
fi

# Solicitar o nome do banco de dados e do usuário
read -p "Digite o nome do banco de dados a ser criado (padrão: zabbix_db): " DB_NAME
DB_NAME=${DB_NAME:-zabbix_db}
read -p "Digite o nome do usuário do banco de dados (padrão: zabbix_user): " DB_USER
DB_USER=${DB_USER:-zabbix_user}

# Solicitar senhas
read -s -p "Insira a senha do root do MySQL: " MYSQL_ROOT_PASSWORD
echo
read -s -p "Insira a senha para o usuário do Zabbix: " ZABBIX_USER_PASSWORD
echo

clear
# Verificação de permissão de root
if [[ "$EUID" -ne 0 ]]; then
    echo "Por favor, execute este script como root."
    exit 1
fi

# Remover instalação anterior
remove_existing

# Configurar timezone e locale
echo "Configurando timezone e locale..."
timedatectl set-timezone "America/Sao_Paulo"
locale-gen "pt_BR.UTF-8" > /dev/null 2>&1
update-locale LANG="pt_BR.UTF-8" > /dev/null 2>&1

# Instalar pacotes necessários
echo "Atualizando o sistema e instalando pacotes..."
apt update -y > /dev/null 2>&1
apt install -y wget gnupg2 software-properties-common mysql-server nano > /dev/null 2>&1

# Resto do script continua daqui...
