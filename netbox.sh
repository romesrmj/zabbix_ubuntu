#!/bin/bash

LOG_FILE="/var/log/netbox_install.log"
exec > >(tee -a ${LOG_FILE}) 2>&1  # Redireciona a saída para o arquivo de log

# Função para executar comandos e exibir mensagens de erro detalhadas
executar_comando() {
    comando=$1
    erro_msg=$2
    if ! eval "$comando"; then
        echo "Erro: $erro_msg. Verifique o log de instalação em $LOG_FILE para mais detalhes."
        exit 1
    fi
}

# Função para coletar o IP do servidor
obter_ip_servidor() {
    ip=$(hostname -I | awk '{print $1}')
    echo $ip
}

# Função para criar o usuário Netbox, se necessário
criar_usuario_netbox() {
    if ! id -u netbox >/dev/null 2>&1; then
        echo "Criando usuário Netbox..."
        executar_comando "sudo adduser --system --group netbox" "Falha ao criar usuário do sistema Netbox."
    else
        echo "Usuário 'netbox' já existe, continuando..."
    fi
}

# Função para criar o banco de dados e o usuário do PostgreSQL
criar_banco_postgres() {
    sudo -u postgres psql -c "CREATE DATABASE dbnetbox;" 
    sudo -u postgres psql -c "CREATE USER usrnetbox WITH PASSWORD '$NETBOX_DB_PASSWORD';"
    sudo -u postgres psql -c "ALTER DATABASE dbnetbox OWNER TO usrnetbox;"
    sudo -u postgres psql -c "GRANT CREATE ON SCHEMA public TO usrnetbox;" 
}

# Atualizando o sistema
executar_comando "sudo apt update && sudo apt upgrade -y" "Falha ao atualizar pacotes do sistema."

# Instalando pacotes necessários
executar_comando "sudo apt install -y postgresql redis-server python3 python3-pip python3-venv python3-dev build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev libssl-dev zlib1g-dev wget" "Falha ao instalar pacotes necessários."

# Verificando a versão do PostgreSQL
psql_version=$(psql -V | awk '{print $3}')
if [[ $(echo $psql_version | cut -d. -f1) -lt 11 ]]; then
    echo "A versão do PostgreSQL é inferior a 11. Atualize para a versão necessária."
    exit 1
fi

# Verificando a versão do Redis
redis_version=$(redis-server -v | awk '{print $3}' | cut -d= -f2)
if [[ $(echo $redis_version | cut -d. -f1) -lt 4 ]]; then
    echo "A versão do Redis é inferior a 4.0. Atualize para a versão necessária."
    exit 1
fi

# Coletando o IP do servidor
server_ip=$(obter_ip_servidor)

# Solicitando a senha do banco de dados do Netbox
echo "Digite a senha para o usuário do banco de dados Netbox:"
read -s NETBOX_DB_PASSWORD

# Criando o banco de dados e o usuário no PostgreSQL
criar_banco_postgres

# Instalando a última versão estável do Netbox
cd /tmp
NETBOX_VERSION="v3.5.8"
executar_comando "wget https://github.com/netbox-community/netbox/archive/refs/tags/$NETBOX_VERSION.tar.gz" "Falha ao baixar o Netbox."
executar_comando "sudo tar -xzf $NETBOX_VERSION.tar.gz -C /opt" "Falha ao extrair o Netbox."
sudo ln -s /opt/netbox-$NETBOX_VERSION /opt/netbox

# Criando o usuário Netbox
criar_usuario_netbox

# Alterando as permissões dos diretórios do Netbox
executar_comando "sudo chown --recursive netbox /opt/netbox/netbox/media/" "Falha ao ajustar permissões do diretório /opt/netbox/netbox/media/."
executar_comando "sudo chown --recursive netbox /opt/netbox/netbox/reports/" "Falha ao ajustar permissões do diretório /opt/netbox/netbox/reports/."
executar_comando "sudo chown --recursive netbox /opt/netbox/netbox/scripts/" "Falha ao ajustar permissões do diretório /opt/netbox/netbox/scripts/."

# Copiando o arquivo de configuração e gerando a chave secreta
cd /opt/netbox/netbox
executar_comando "sudo cp configuration_example.py configuration.py" "Falha ao copiar arquivo de configuração."
SECRET_KEY=$(python3 generate_secret_key.py)
sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['$server_ip']/" configuration.py
sed -i "s/DATABASE = {/DATABASE = {\n    'NAME': 'dbnetbox',\n    'USER': 'usrnetbox',\n    'PASSWORD': '$NETBOX_DB_PASSWORD',/" configuration.py
sed -i "s/SECRET_KEY = '.*'/SECRET_KEY = '$SECRET_KEY'/" configuration.py
sed -i "s/LOGIN_REQUIRED = False/LOGIN_REQUIRED = True/" configuration.py

# Instalando pacotes do Python necessários
executar_comando "sudo /opt/netbox/upgrade.sh" "Falha ao executar script de upgrade do Netbox."

# Criando o super usuário do Netbox
cd /opt/netbox/netbox
executar_comando "source /opt/netbox/venv/bin/activate && python3 manage.py createsuperuser" "Falha ao criar superusuário do Netbox."

# Configurando a tarefa de limpeza
executar_comando "sudo ln -s /opt/netbox/contrib/netbox-housekeeping.sh /etc/cron.daily/netbox-housekeeping" "Falha ao configurar a tarefa de limpeza."

# Iniciando o servidor de teste
executar_comando "source /opt/netbox/venv/bin/activate && python3 manage.py runserver 0.0.0.0:8000 --insecure" "Falha ao iniciar o servidor de teste do Netbox."

# Instalação completa com sucesso
echo "Instalação do Netbox concluída com sucesso. Acesse http://$server_ip:8000 para confirmar."
echo "Usuário administrador: netbox"
echo "Senha do banco de dados Netbox: $NETBOX_DB_PASSWORD"
