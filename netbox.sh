#!/bin/bash

# Função para log de erros
log_error() {
    echo "[ERRO] $1"
    echo "[ERRO] $1" >> /var/log/netbox_install.log
}

# Função para log de sucesso
log_success() {
    echo "[SUCESSO] $1"
    echo "[SUCESSO] $1" >> /var/log/netbox_install.log
}

# Função para verificar sucesso de comandos
check_command_success() {
    if [ $? -ne 0 ]; then
        log_error "$1"
        exit 1
    fi
}

# Limpar a tela
clear

echo "Iniciando instalação do NetBox..."

# Atualizando o sistema
log_success "Atualizando pacotes do sistema..."
apt-get update -y && apt-get upgrade -y
check_command_success "Falha ao atualizar pacotes do sistema."

# Instalando dependências essenciais
log_success "Instalando dependências do sistema..."
apt-get install -y wget curl python3 python3-pip python3-venv python3-dev build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev libssl-dev zlib1g-dev
check_command_success "Falha ao instalar dependências essenciais."

# Verificando a versão do Python
echo "Verificando a versão do Python..."

# Verificar se o python3 está instalado corretamente
if ! command -v python3 &>/dev/null; then
    log_error "Python 3 não encontrado. Instalando Python 3..."
    apt-get install -y python3
    check_command_success "Falha ao instalar Python 3."
fi

# Garantir que o comando python esteja configurado corretamente
if ! command -v python &>/dev/null; then
    echo "Criando link simbólico para python..."
    ln -s /usr/bin/python3 /usr/bin/python
    check_command_success "Falha ao criar o link simbólico para python."
    log_success "Link simbólico para python criado."
fi

# Pegando a versão do Python
python_version=$(python3 --version | awk '{print $2}')
required_version="3.8"

# Comparando versões de forma robusta
version_check=$(echo -e "$required_version\n$python_version" | sort -V | head -n1)

if [[ "$version_check" == "$required_version" ]]; then
    log_success "Versão do Python verificada: $python_version (compatível)."
else
    log_error "A versão do Python não é compatível. Versão mínima requerida: 3.8. Você tem a versão $python_version."
    exit 1
fi

# Instalando o PostgreSQL
log_success "Instalando PostgreSQL..."
apt-get install -y postgresql
check_command_success "Falha ao instalar PostgreSQL."

# Criando banco de dados e usuário no PostgreSQL
log_success "Criando banco de dados e usuário no PostgreSQL..."
sudo -u postgres psql -c "CREATE DATABASE dbnetbox;"
sudo -u postgres psql -c "CREATE USER usrnetbox WITH PASSWORD 'senha_secure';"
sudo -u postgres psql -c "ALTER ROLE usrnetbox SET client_encoding TO 'utf8';"
sudo -u postgres psql -c "ALTER ROLE usrnetbox SET default_transaction_isolation TO 'read committed';"
sudo -u postgres psql -c "ALTER ROLE usrnetbox SET timezone TO 'UTC';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE dbnetbox TO usrnetbox;"
check_command_success "Falha ao configurar banco de dados no PostgreSQL."

# Instalando o Redis
log_success "Instalando Redis..."
apt-get install -y redis-server
check_command_success "Falha ao instalar Redis."

# Instalando dependências do Python no ambiente virtual
log_success "Criando ambiente virtual Python e instalando dependências..."
python3 -m venv /opt/netbox/netbox/venv
check_command_success "Falha ao criar o ambiente virtual Python."

# Ativando o ambiente virtual e instalando as dependências
source /opt/netbox/netbox/venv/bin/activate
pip install -r /opt/netbox/netbox/requirements.txt
check_command_success "Falha ao instalar dependências do Python."

# Configurando o NetBox
log_success "Configurando o NetBox..."
cp /opt/netbox/netbox/netbox/configuration_example.py /opt/netbox/netbox/netbox/configuration.py
check_command_success "Falha ao copiar arquivo de configuração."

# Aplicando migrações do banco de dados
log_success "Aplicando migrações do banco de dados..."
python /opt/netbox/netbox/manage.py migrate
check_command_success "Falha ao aplicar migrações do banco de dados."

# Coletando arquivos estáticos
log_success "Coletando arquivos estáticos..."
python /opt/netbox/netbox/manage.py collectstatic --noinput
check_command_success "Falha ao coletar arquivos estáticos."

# Iniciando o NetBox
log_success "Iniciando o NetBox..."
python /opt/netbox/netbox/manage.py runserver 0.0.0.0:8000 &
check_command_success "Falha ao iniciar o NetBox."

# Exibindo informações de login
server_ip=$(hostname -I | awk '{print $1}')
log_success "NetBox iniciado. Acesse http://$server_ip:8000 para confirmar."

# Informações de login
echo "Usuários e senhas para login:"
echo "Usuário: admin"
echo "Senha: password"
