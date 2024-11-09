#!/bin/bash

# Define log file for installation errors
LOG_FILE="/var/log/netbox_install.log"

# Função para registrar erros e falhas
log_error() {
    echo "Erro: $1" | tee -a $LOG_FILE
    exit 1
}

# Função para registrar sucesso
log_success() {
    echo "Sucesso: $1" | tee -a $LOG_FILE
}

# Atualização do sistema
echo "Atualizando o sistema..."
sudo apt-get update && sudo apt-get upgrade -y || log_error "Falha ao atualizar pacotes do sistema."

# Instalação do PostgreSQL
echo "Instalando o PostgreSQL..."
sudo apt-get install -y postgresql || log_error "Falha ao instalar PostgreSQL."
postgres_version=$(psql -V | awk '{print $3}')
echo "Versão do PostgreSQL: $postgres_version"

# Verificar a versão do PostgreSQL
if [[ "$(echo $postgres_version | cut -d. -f1)" -lt 11 ]]; then
    log_error "Versão do PostgreSQL instalada é inferior a 11. Instale a versão 11 ou superior."
fi

# Configuração do PostgreSQL
echo "Configurando o PostgreSQL..."
sudo -u postgres psql <<EOF
CREATE DATABASE dbnetbox;
CREATE USER usrnetbox WITH PASSWORD '$(openssl rand -base64 32)';
ALTER DATABASE dbnetbox OWNER TO usrnetbox;
EOF
log_success "Banco de dados e usuário do PostgreSQL criados com sucesso."

# Instalação do Redis
echo "Instalando o Redis..."
sudo apt-get install -y redis-server || log_error "Falha ao instalar o Redis."
redis_version=$(redis-server -v | awk '{print $3}')
echo "Versão do Redis: $redis_version"

# Verificação do Redis
echo "Verificando o status do Redis..."
redis-cli ping | grep -q "PONG" || log_error "Falha na conexão com o Redis."

# Instalação do Python e pacotes necessários
echo "Instalando o Python 3 e dependências..."
sudo apt-get install -y python3 python3-pip python3-venv python3-dev build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev libssl-dev zlib1g-dev || log_error "Falha ao instalar o Python e dependências."
python_version=$(python3 -V | awk '{print $2}')
echo "Versão do Python: $python_version"

if [[ "$(echo $python_version | cut -d. -f1)" -lt 3 || "$(echo $python_version | cut -d. -f2)" -lt 8 ]]; then
    log_error "Versão do Python instalada é inferior a 3.8. Instale a versão 3.8 ou superior."
fi

# Baixando o Netbox
echo "Baixando o Netbox..."
cd /tmp || log_error "Falha ao acessar o diretório /tmp."
wget https://github.com/netbox-community/netbox/archive/refs/tags/v3.5.8.tar.gz || log_error "Falha ao baixar o arquivo do Netbox."
tar -xzf v3.5.8.tar.gz -C /opt || log_error "Falha ao extrair o arquivo do Netbox."

# Criando o link simbólico
echo "Criando link simbólico do Netbox..."
sudo ln -s /opt/netbox-3.5.8 /opt/netbox || log_error "Falha ao criar o link simbólico."

# Criando usuário do sistema para o Netbox
echo "Criando usuário 'netbox'..."
sudo adduser --system --group netbox || log_error "Falha ao criar usuário do sistema Netbox."

# Alterando permissões dos diretórios
echo "Alterando permissões para o usuário 'netbox'..."
sudo chown --recursive netbox /opt/netbox/netbox/media/
sudo chown --recursive netbox /opt/netbox/netbox/reports/
sudo chown --recursive netbox /opt/netbox/netbox/scripts/
log_success "Permissões alteradas com sucesso."

# Copiando e configurando o arquivo de configuração
echo "Configurando o arquivo de configuração..."
cd /opt/netbox/netbox/netbox || log_error "Falha ao acessar o diretório do Netbox."
if [ ! -f "configuration_example.py" ]; then
    log_error "Arquivo configuration_example.py não encontrado."
fi
sudo cp configuration_example.py configuration.py || log_error "Falha ao copiar arquivo de configuração."

# Gerando a secret_key
echo "Gerando chave secreta..."
secret_key=$(python3 ../generate_secret_key.py)
echo "SECRET_KEY gerada com sucesso."

# Atualizando o arquivo de configuração
echo "Atualizando arquivo de configuração..."
sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['$(hostname -I | awk '{print $1}')']/g" /opt/netbox/netbox/netbox/configuration.py || log_error "Falha ao atualizar ALLOWED_HOSTS."
sed -i "s/DATABASE = {.*}/DATABASE = {\n    'ENGINE': 'django.db.backends.postgresql',\n    'NAME': 'dbnetbox',\n    'USER': 'usrnetbox',\n    'PASSWORD': '$(openssl rand -base64 32)',\n    'HOST': 'localhost',\n    'PORT': '',\n    'CONN_MAX_AGE': 300,\n}/g" /opt/netbox/netbox/netbox/configuration.py || log_error "Falha ao atualizar banco de dados."
sed -i "s/SECRET_KEY = '.*'/SECRET_KEY = '$secret_key'/g" /opt/netbox/netbox/netbox/configuration.py || log_error "Falha ao atualizar a chave secreta."
sed -i "s/LOGIN_REQUIRED = False/LOGIN_REQUIRED = True/g" /opt/netbox/netbox/netbox/configuration.py || log_error "Falha ao configurar LOGIN_REQUIRED."

# Instalando dependências do Netbox
echo "Instalando dependências do Netbox..."
cd /opt/netbox || log_error "Falha ao acessar o diretório do Netbox."
sudo python3 -m venv venv || log_error "Falha ao criar ambiente virtual."
source venv/bin/activate || log_error "Falha ao ativar ambiente virtual."
pip install -r requirements.txt || log_error "Falha ao instalar dependências do Python."
log_success "Dependências instaladas com sucesso."

# Realizando as migrações do banco de dados
echo "Realizando migrações do banco de dados..."
python3 /opt/netbox/netbox/manage.py migrate || log_error "Falha ao realizar migrações do banco de dados."
log_success "Migrações do banco de dados concluídas."

# Criando superusuário
echo "Criando superusuário do Netbox..."
python3 /opt/netbox/netbox/manage.py createsuperuser || log_error "Falha ao criar superusuário."
log_success "Superusuário criado com sucesso."

# Iniciando o Gunicorn
echo "Iniciando o Gunicorn..."
sudo cp /opt/netbox/contrib/gunicorn.py /opt/netbox/gunicorn.py || log_error "Falha ao configurar Gunicorn."
sudo cp /opt/netbox/contrib/*.service /etc/systemd/system/ || log_error "Falha ao configurar systemd."
sudo systemctl daemon-reload || log_error "Falha ao recarregar systemd."
sudo systemctl start netbox netbox-rq || log_error "Falha ao iniciar serviços do Netbox."
sudo systemctl enable netbox netbox-rq || log_error "Falha ao habilitar serviços do Netbox."
log_success "Gunicorn iniciado e serviços configurados."

# Instalando o Apache e configurando SSL
echo "Instalando o Apache2 e configurando SSL..."
sudo apt-get install -y apache2 || log_error "Falha ao instalar o Apache2."
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/netbox.key -out /etc/ssl/certs/netbox.crt || log_error "Falha ao gerar certificado SSL."
sudo cp /opt/netbox/contrib/apache.conf /etc/apache2/sites-available/netbox.conf || log_error "Falha ao configurar Apache."
sudo a2enmod ssl proxy proxy_http headers rewrite || log_error "Falha ao habilitar módulos do Apache."
sudo a2ensite netbox || log_error "Falha ao habilitar site do Netbox."
sudo systemctl restart apache2 || log_error "Falha ao reiniciar o Apache."

# Mensagem de conclusão
server_ip=$(hostname -I | awk '{print $1}')
superuser=$(cat /opt/netbox/netbox/netbox/configuration.py | grep 'SUPERUSER' | awk -F"'" '{print $2}')
echo "Instalação do Netbox concluída com sucesso. Acesse http://$server_ip:8000 para confirmar." | tee -a $LOG_FILE
echo "Usuário do sistema: netbox"
echo "Senha do banco de dados: $(openssl rand -base64 32)" | tee -a $LOG_FILE
echo "Usuário
