#!/bin/bash

LOG_FILE="/var/log/netbox_install.log"

# Função para registrar mensagens de erro
log_error() {
    echo "Erro: $1" | tee -a $LOG_FILE
    exit 1
}

# Função para registrar mensagens de sucesso
log_success() {
    echo "Sucesso: $1" | tee -a $LOG_FILE
}

# Atualizando o sistema
echo "Atualizando o sistema..."
sudo apt-get update -y || log_error "Falha ao atualizar o sistema."
sudo apt-get upgrade -y || log_error "Falha ao realizar upgrade do sistema."
log_success "Sistema atualizado com sucesso."

# Instalando dependências necessárias
echo "Instalando dependências..."
sudo apt-get install -y postgresql redis-server python3 python3-pip python3-venv python3-dev build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev libssl-dev zlib1g-dev wget curl || log_error "Falha ao instalar dependências."
log_success "Dependências instaladas com sucesso."

# Verificando versão do PostgreSQL
echo "Verificando a versão do PostgreSQL..."
psql_version=$(psql -V | awk '{print $3}')
if [[ $(echo "$psql_version >= 11" | bc -l) -eq 0 ]]; then
    log_error "A versão do PostgreSQL não é compatível. Versão mínima requerida: 11. Você tem a versão $psql_version."
fi
log_success "Versão do PostgreSQL verificada: $psql_version."

# Verificando versão do Python
echo "Verificando a versão do Python..."
python_version=$(python3 -V 2>&1 | awk '{print $2}')
if [[ $(echo "$python_version >= 3.8" | bc -l) -eq 0 ]]; then
    log_error "A versão do Python não é compatível. Versão mínima requerida: 3.8. Você tem a versão $python_version."
fi
log_success "Versão do Python verificada: $python_version."

# Verificando se o usuário 'netbox' já existe
echo "Criando usuário 'netbox'..."
if id "netbox" &>/dev/null; then
    echo "Usuário 'netbox' já existe, removendo e criando novamente como usuário de sistema."
    sudo deluser netbox || log_error "Falha ao remover o usuário 'netbox'."
fi

# Criando usuário do sistema para o Netbox
sudo adduser --system --group netbox || log_error "Falha ao criar o usuário do sistema Netbox."

# Alterando permissões dos diretórios
echo "Alterando permissões para o usuário 'netbox'..."
sudo chown --recursive netbox /opt/netbox/netbox/media/
sudo chown --recursive netbox /opt/netbox/netbox/reports/
sudo chown --recursive netbox /opt/netbox/netbox/scripts/
log_success "Permissões alteradas com sucesso."

# Baixando e extraindo o Netbox
echo "Baixando e extraindo o Netbox..."
cd /tmp || log_error "Falha ao acessar o diretório /tmp."
wget https://github.com/netbox-community/netbox/archive/refs/tags/v3.5.8.tar.gz || log_error "Falha ao baixar o Netbox."
tar -xzf v3.5.8.tar.gz -C /opt || log_error "Falha ao extrair o Netbox."

# Verificando se o link simbólico já existe
if [ -L /opt/netbox ]; then
    echo "Link simbólico já existe. Removendo o link antigo..."
    sudo rm -f /opt/netbox || log_error "Falha ao remover o link simbólico anterior."
fi

# Criando link simbólico para o Netbox
sudo ln -s /opt/netbox-3.5.8/ /opt/netbox || log_error "Falha ao criar link simbólico do Netbox."
log_success "Link simbólico criado com sucesso."

# Criando arquivo de configuração
echo "Criando arquivo de configuração do Netbox..."
cd /opt/netbox/netbox || log_error "Falha ao acessar o diretório do Netbox."
cp configuration_example.py configuration.py || log_error "Falha ao copiar o arquivo de configuração."
log_success "Arquivo de configuração copiado com sucesso."

# Gerando a chave secreta
echo "Gerando chave secreta..."
secret_key=$(python3 ../generate_secret_key.py) || log_error "Falha ao gerar chave secreta."
log_success "Chave secreta gerada com sucesso."

# Atualizando arquivo de configuração com as informações do banco de dados e chave secreta
echo "Atualizando arquivo de configuração com dados do banco de dados e chave secreta..."
sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = \['$server_ip'\]/" /opt/netbox/netbox/configuration.py
sed -i "s/DATABASE = {.*}/DATABASE = {\n    'ENGINE': 'django.db.backends.postgresql',\n    'NAME': 'dbnetbox',\n    'USER': 'usrnetbox',\n    'PASSWORD': 'senha_do_usuario',\n    'HOST': 'localhost',\n    'PORT': '',\n    'CONN_MAX_AGE': 300\n}/" /opt/netbox/netbox/configuration.py
sed -i "s/SECRET_KEY = '.*'/SECRET_KEY = '$secret_key'/" /opt/netbox/netbox/configuration.py
sed -i "s/LOGIN_REQUIRED = False/LOGIN_REQUIRED = True/" /opt/netbox/netbox/configuration.py
log_success "Arquivo de configuração atualizado com sucesso."

# Atualizando o script de instalação do Netbox
echo "Atualizando o script de instalação do Netbox..."
sudo /opt/netbox/upgrade.sh || log_error "Falha ao executar o script de upgrade do Netbox."
log_success "Script de upgrade do Netbox executado com sucesso."

# Criando o superusuário do Netbox
echo "Criando superusuário do Netbox..."
source /opt/netbox/venv/bin/activate || log_error "Falha ao ativar ambiente virtual do Netbox."
cd /opt/netbox/netbox || log_error "Falha ao acessar o diretório do Netbox."
python3 manage.py createsuperuser || log_error "Falha ao criar superusuário do Netbox."
deactivate || log_error "Falha ao desativar o ambiente virtual do Netbox."
log_success "Superusuário do Netbox criado com sucesso."

# Configurando a tarefa de limpeza diária
echo "Configurando tarefa de limpeza diária..."
sudo ln -s /opt/netbox/contrib/netbox-housekeeping.sh /etc/cron.daily/netbox-housekeeping || log_error "Falha ao configurar a tarefa de limpeza."
log_success "Tarefa de limpeza configurada com sucesso."

# Testando o ambiente
echo "Testando o ambiente..."
python3 manage.py runserver 0.0.0.0:8000 --insecure || log_error "Falha ao iniciar o servidor de teste."
log_success "Ambiente de teste iniciado com sucesso. Acesse http://$server_ip:8000 para confirmar."

# Finalizando a instalação
echo "Instalação do Netbox concluída com sucesso!"
echo "Acesse http://$server_ip:8000 para confirmar."
echo "Usuário: admin"
echo "Senha: senha_do_superusuario"
echo "Banco de dados: dbnetbox"
echo "Usuário do banco: usrnetbox"
echo "Senha do banco: senha_do_usuario"

# Finalizando o script
exit 0
