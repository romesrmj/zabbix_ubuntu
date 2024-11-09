#!/bin/bash

# Função para exibir mensagens de sucesso
log_success() {
    echo -e "\e[32m[SUCESSO] $1\e[0m"
}

# Função para exibir mensagens de erro
log_error() {
    echo -e "\e[31m[ERRO] $1\e[0m"
    echo "Verifique o log de instalação em /var/log/netbox_install.log para mais detalhes."
    exit 1
}

# Limpeza de tela
clear

# Iniciando o processo de instalação do Netbox
echo "Iniciando o deploy do Netbox..."

# Verificando se o script está sendo executado como root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Este script precisa ser executado como root ou com permissões sudo."
fi

# Atualizando pacotes
echo "Atualizando pacotes do sistema..."
apt-get update -y && apt-get upgrade -y

# Instalando dependências
echo "Instalando dependências necessárias..."
apt-get install -y wget curl git python3 python3-pip python3-dev python3-venv build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev libssl-dev zlib1g-dev redis-server postgresql

log_success "Dependências instaladas com sucesso."

# Verificando a versão do PostgreSQL
echo "Verificando a versão do PostgreSQL..."
postgres_version=$(psql --version | awk '{print $3}')
log_success "Versão do PostgreSQL verificada: $postgres_version."

# Verificando e corrigindo versão do Python
echo "Verificando a versão do Python..."

# Remover versões antigas do Python se existirem
for ver in $(dpkg -l | grep python3 | awk '{print $2}' | grep -v python3.12); do
    echo "Removendo versão antiga do Python: $ver"
    apt-get purge -y $ver
done

# Garantir que o Python 3.12 esteja instalado
python_version=$(python3 --version | awk '{print $2}')
required_version="3.8"

# Comparando as versões
if [[ "$(printf '%s\n' "$required_version" "$python_version" | sort -V | head -n1)" != "$required_version" ]]; then
    log_success "Versão do Python verificada: $python_version."
else
    log_error "A versão do Python não é compatível. Versão mínima requerida: 3.8. Você tem a versão $python_version."
fi

log_success "Versão do Python verificada: $python_version."

# Instalando o Redis
echo "Instalando o Redis..."
apt-get install -y redis-server
log_success "Versão do Redis instalada com sucesso."

# Verificando o status do Redis
systemctl status redis | grep "active (running)" &>/dev/null
if [ $? -ne 0 ]; then
    log_error "Redis não está ativo. Verifique o status e reinicie o serviço."
fi
log_success "Redis está em execução."

# Criando o banco de dados e usuário PostgreSQL
echo "Configurando o PostgreSQL..."
DB_NAME="dbnetbox"
DB_USER="usrnetbox"

# Garantir que o banco e usuário não existem
psql -U postgres -c "DROP DATABASE IF EXISTS $DB_NAME;"
psql -U postgres -c "DROP USER IF EXISTS $DB_USER;"

# Criando o banco de dados e usuário
psql -U postgres -c "CREATE USER $DB_USER WITH PASSWORD 'password';"
psql -U postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
psql -U postgres -c "ALTER DATABASE $DB_NAME SET timezone TO 'UTC';"

log_success "Banco de dados e usuário do PostgreSQL criados com sucesso."

# Baixando o NetBox
echo "Baixando o NetBox..."
wget https://github.com/netbox-community/netbox/archive/refs/tags/v3.5.8.tar.gz -O /tmp/netbox-v3.5.8.tar.gz

log_success "NetBox baixado com sucesso."

# Extraindo o arquivo do NetBox
echo "Extraindo o NetBox..."
tar -xzvf /tmp/netbox-v3.5.8.tar.gz -C /opt/

# Criando o link simbólico
echo "Criando link simbólico do NetBox..."
ln -sfn /opt/netbox/netbox-3.5.8 /opt/netbox/netbox

# Criando o usuário do sistema
echo "Criando usuário 'netbox'..."
if id "netbox" &>/dev/null; then
    echo "Usuário 'netbox' já existe, continuando..."
else
    adduser --system --group --disabled-password --gecos "" netbox
fi

log_success "Usuário 'netbox' criado com sucesso."

# Instalando dependências do Python
echo "Instalando dependências do Python..."
cd /opt/netbox/netbox && python3 -m venv venv
source /opt/netbox/netbox/venv/bin/activate
pip install -r /opt/netbox/netbox/requirements.txt

log_success "Dependências do Python instaladas com sucesso."

# Configurando o NetBox
echo "Configurando o NetBox..."
cp /opt/netbox/netbox/netbox/configuration_example.py /opt/netbox/netbox/netbox/configuration.py
sed -i "s/'DATABASES'.*/'DATABASES': {'default': {'ENGINE': 'django.db.backends.postgresql', 'NAME': '$DB_NAME', 'USER': '$DB_USER', 'PASSWORD': 'password', 'HOST': 'localhost', 'PORT': '5432'}},/" /opt/netbox/netbox/netbox/configuration.py
sed -i "s/'ALLOWED_HOSTS'.*/'ALLOWED_HOSTS': ['*'],/" /opt/netbox/netbox/netbox/configuration.py

log_success "Configuração do NetBox concluída."

# Executando as migrações do banco de dados
echo "Aplicando migrações do banco de dados..."
source /opt/netbox/netbox/venv/bin/activate
cd /opt/netbox/netbox
./manage.py migrate

log_success "Migrações do banco de dados aplicadas com sucesso."

# Criando os arquivos estáticos
echo "Coletando arquivos estáticos..."
./manage.py collectstatic --noinput

log_success "Arquivos estáticos coletados com sucesso."

# Iniciando o NetBox
echo "Iniciando o NetBox..."
./manage.py runserver 0.0.0.0:8000 &

log_success "NetBox iniciado. Acesse http://<IP_DO_SEU_SERVIDOR>:8000 para confirmar."

echo "Usuários e senhas para login:"
echo "Usuário: admin"
echo "Senha: password"
