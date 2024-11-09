#!/bin/bash

# Limpar a tela no início
clear

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

# Função para limpar qualquer resquício de instalação anterior
clean_previous_installation() {
    echo "Removendo qualquer instalação anterior..."
    sudo rm -rf /opt/netbox/netbox-3.5.8
    sudo rm -f /opt/netbox/netbox || true
    sudo userdel -r netbox || true
    sudo dropdb dbnetbox || true
    sudo dropuser usrnetbox || true
    sudo rm -f /opt/netbox/netbox-3.5.8.tar.gz
    log_success "Instalação anterior removida com sucesso."
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

# Limpeza de qualquer resquício de instalação anterior
clean_previous_installation

# Baixando o Netbox
echo "Baixando o Netbox..."
cd /opt || log_error "Falha ao acessar o diretório /opt."
wget https://github.com/netbox-community/netbox/archive/refs/tags/v3.5.8.tar.gz -O netbox-3.5.8.tar.gz || log_error "Falha ao baixar o Netbox."

# Descompactando o arquivo
echo "Descompactando o Netbox..."
tar -xvzf netbox-3.5.8.tar.gz || log_error "Falha ao descompactar o Netbox."
log_success "Netbox descompactado com sucesso."

# Removendo o link simbólico anterior, caso exista
if [ -L /opt/netbox/netbox-3.5.8 ]; then
    echo "Link simbólico já existe. Removendo..."
    sudo rm /opt/netbox/netbox-3.5.8 || log_error "Falha ao remover link simbólico antigo."
fi

# Criando o link simbólico
echo "Criando link simbólico do Netbox..."
sudo ln -s /opt/netbox/netbox-3.5.8 /opt/netbox/netbox || log_error "Falha ao criar o link simbólico."
log_success "Link simbólico criado com sucesso."

# Criando o usuário do sistema para o Netbox
echo "Criando o usuário 'netbox'..."
if ! id "netbox" &>/dev/null; then
    sudo useradd --system --group --create-home netbox || log_error "Falha ao criar usuário do sistema Netbox."
    log_success "Usuário 'netbox' criado com sucesso."
else
    echo "Usuário 'netbox' já existe. Continuando..."
fi

# Criando o banco de dados e usuário no PostgreSQL
echo "Configurando o banco de dados e usuário do PostgreSQL..."
sudo -u postgres psql -c "CREATE DATABASE dbnetbox;" || log_error "Falha ao criar o banco de dados dbnetbox."
sudo -u postgres psql -c "CREATE USER usrnetbox WITH PASSWORD 'your_password';" || log_error "Falha ao criar o usuário usrnetbox."
sudo -u postgres psql -c "ALTER DATABASE dbnetbox OWNER TO usrnetbox;" || log_error "Falha ao vincular o banco de dados ao usuário."
log_success "Banco de dados e usuário do PostgreSQL configurados com sucesso."

# Copiando o arquivo de configuração
echo "Copiando o arquivo de configuração..."
if [ -f /opt/netbox/netbox-3.5.8/netbox/configuration_example.py ]; then
    sudo cp /opt/netbox/netbox-3.5.8/netbox/configuration_example.py /opt/netbox/netbox-3.5.8/netbox/configuration.py || log_error "Falha ao copiar o arquivo de configuração."
    log_success "Arquivo de configuração copiado com sucesso."
else
    log_error "Arquivo configuration_example.py não encontrado."
fi

# Finalizando a instalação do Netbox (exemplo de configuração de banco de dados e outras etapas)
echo "Instalação do Netbox concluída com sucesso."
echo "Acesse o Netbox através de: http://<IP_DO_SERVIDOR>:8000"
echo "Usuário: admin"
echo "Senha: admin_password"  # Substitua isso por uma senha real ou uma variável
