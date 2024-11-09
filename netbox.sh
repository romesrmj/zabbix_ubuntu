#!/bin/bash

# Arquivo de log
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
executar_comando "sudo apt install -y postgresql redis-server python3 python3-pip python3-venv python3-dev build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev libssl-dev zlib1g-dev wget git" "Falha ao instalar pacotes necessários."

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

# Instalando o Netbox a partir do repositório GitHub
cd /opt
if [ ! -d "/opt/netbox" ]; then
    echo "Clonando o repositório do Netbox..."
    git clone https://github.com/netbox-community/netbox.git
else
    echo "Repositório Netbox já clonado, atualizando..."
    cd /opt/netbox
    git pull origin master
fi

# Verificando a versão mais recente do Netbox
NETBOX_VERSION=$(git describe --tags)
echo "Versão do Netbox instalada: $NETBOX_VERSION"

# Criando o usuário Netbox
criar_usuario_netbox

# Alterando as permissões dos diretórios do Netbox
executar_comando "sudo chown --recursive netbox /opt/netbox/netbox/media/" "Falha ao ajustar permissões do diretório /opt/netbox/netbox/media/."
executar_comando "sudo chown --recursive netbox /opt/netbox/netbox/reports/" "Falha ao ajustar permissões do diretório /opt/netbox/netbox/reports/."
executar_comando "sudo chown --recursive netbox /opt/netbox/netbox/scripts/" "Falha ao ajustar permissões do diretório /opt/netbox/netbox/scripts/."

# Verificando e copiando o arquivo de configuração
if [ ! -f "/opt/netbox/netbox/configuration_example.py" ]; then
    echo "Arquivo 'configuration_example.py' não encontrado, fazendo download do arquivo de configuração..."
    wget -O /opt/netbox/netbox/configuration_example.py https://raw.githubusercontent.com/netbox-community/netbox/master/netbox/configuration_example.py
fi

# Copiando o arquivo de configuração para o local adequado
executar_comando "sudo cp /opt/netbox/netbox/configuration_example.py /opt/netbox/netbox/configuration.py" "Falha ao copiar arquivo de configuração."

# Gerando a chave secreta e configurando o Netbox
SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_urlsafe())')
sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['$server_ip']/" /opt/netbox/netbox/configuration.py
sed -i "s/DATABASE = {/DATABASE = {\n    'NAME': 'dbnetbox',\n    'USER': 'usrnetbox',\n    'PASSWORD': '$NETBOX_DB_PASSWORD',/" /opt/netbox/netbox/configuration.py
sed -i "s/SECRET_KEY = '.*'/SECRET_KEY = '$SECRET_KEY'/" /opt/netbox/netbox/configuration.py
sed -i "s/LOGIN_REQUIRED = False/LOGIN_REQUIRED = True/" /opt/netbox/netbox/configuration.py

# Instalando pacotes do Python necessários
executar_comando "sudo pip3 install -r /opt/netbox/requirements.txt" "Falha ao instalar pacotes Python do Netbox."

# Configurando o ambiente virtual do Netbox
sudo -u netbox bash -c "cd /opt/netbox && python3 -m venv venv"
sudo -u netbox bash -c "source /opt/netbox/venv/bin/activate && pip install -r /opt/netbox/requirements.txt"

# Migrando o banco de dados do Netbox
executar_comando "sudo -u netbox bash -c 'cd /opt/netbox && source /opt/netbox/venv/bin/activate && python3 manage.py migrate'" "Falha ao migrar o banco de dados do Netbox."

# Criando o superusuário do Netbox
executar_comando "sudo -u netbox bash -c 'cd /opt/netbox && source /opt/netbox/venv/bin/activate && python3 manage.py createsuperuser'" "Falha ao criar superusuário do Netbox."

# Configurando o cron para tarefas do Netbox
executar_comando "sudo ln -s /opt/netbox/contrib/netbox-housekeeping.sh /etc/cron.daily/netbox-housekeeping" "Falha ao configurar a tarefa de limpeza."

# Iniciando o servidor de teste
executar_comando "sudo -u netbox bash -c 'cd /opt/netbox && source /opt/netbox/venv/bin/activate && python3 manage.py runserver 0.0.0.0:8000 --insecure'" "Falha ao iniciar o servidor de teste do Netbox."

# Instalação completa com sucesso
echo "Instalação do Netbox concluída com sucesso. Acesse http://$server_ip:8000 para confirmar."
echo "Usuário administrador: netbox"
echo "Senha do banco de dados Netbox: $NETBOX_DB_PASSWORD"
