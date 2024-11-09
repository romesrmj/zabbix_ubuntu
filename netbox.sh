#!/bin/bash

# Limpar a tela
clear

# Função para verificar o status de um comando e exibir a mensagem de erro em caso de falha
check_command() {
    if [ $? -ne 0 ]; then
        echo "[ERRO] $1"
        exit 1
    fi
}

# Função para exibir uma mensagem de sucesso
success_message() {
    echo "[SUCESSO] $1"
}

# Atualizando o sistema
echo "Atualizando o sistema..."
sudo apt update -y && sudo apt upgrade -y
check_command "Erro ao atualizar o sistema."

# Instalando pacotes necessários
echo "Instalando pacotes necessários..."
sudo apt install -y wget curl python3 python3-pip python3-dev python3-venv postgresql redis-server
check_command "Erro ao instalar pacotes necessários."

# Verificando a versão do Python
python_version=$(python3 --version 2>&1 | awk '{print $2}')
if [[ -z "$python_version" ]]; then
    echo "[ERRO] Python não instalado. Instale o Python 3 antes de continuar."
    exit 1
fi

echo "Versão do Python instalada: $python_version"

# Garantindo que a versão mínima do Python seja 3.8
if [[ $(echo "$python_version < 3.8" | bc) -eq 1 ]]; then
    echo "[ERRO] A versão do Python não é compatível. Versão mínima requerida: 3.8. Você tem a versão $python_version."
    exit 1
fi

# Verificando se o usuário "netbox" já existe
if id "netbox" &>/dev/null; then
    echo "O usuário 'netbox' já existe, verificando se é um usuário de sistema..."
    
    # Obtendo o ID do usuário netbox
    user_uid=$(id -u netbox)
    
    # Se o UID for maior que 1000, é um usuário não-sistema, e o usuário será removido
    if [ "$user_uid" -ge 1000 ]; then
        echo "O usuário 'netbox' não é um usuário de sistema. Removendo..."
        sudo userdel -r netbox
        check_command "Erro ao remover o usuário 'netbox'."
    else
        echo "O usuário 'netbox' já é um usuário de sistema."
    fi
else
    echo "O usuário 'netbox' não existe. Criando..."
fi

# Criando o usuário e grupo do NetBox como sistema
echo "Criando usuário e grupo do NetBox..."
sudo adduser --system --group --disabled-login --disabled-password --gecos "NetBox user" netbox
check_command "Falha ao criar usuário do sistema NetBox."

# Instalando o NetBox
echo "Baixando e instalando o NetBox..."
cd /opt
sudo wget https://github.com/netbox-community/netbox/archive/refs/tags/v3.5.8.tar.gz
check_command "Erro ao baixar o NetBox."

# Extraindo o arquivo baixado
sudo tar -xvzf v3.5.8.tar.gz
check_command "Erro ao extrair o NetBox."

# Criando o link simbólico
echo "Criando link simbólico do NetBox..."
sudo ln -s /opt/netbox-3.5.8 /opt/netbox
check_command "Erro ao criar o link simbólico."

# Criando ambiente virtual Python
echo "Criando ambiente virtual Python..."
cd /opt/netbox
python3 -m venv venv
check_command "Erro ao criar o ambiente virtual."

# Instalando dependências do Python no ambiente virtual
echo "Instalando dependências do Python no ambiente virtual..."
source venv/bin/activate
pip install -r requirements.txt
check_command "Erro ao instalar dependências do Python no ambiente virtual."

# Configurando o NetBox
echo "Configurando o NetBox..."
cp configuration_example.py configuration.py
check_command "Erro ao copiar o arquivo de configuração."

# Aplicando migrações do banco de dados
echo "Aplicando migrações do banco de dados..."
python3 manage.py migrate
check_command "Erro ao aplicar migrações."

# Coletando arquivos estáticos
echo "Coletando arquivos estáticos..."
python3 manage.py collectstatic --noinput
check_command "Erro ao coletar arquivos estáticos."

# Iniciando o NetBox
echo "Iniciando o NetBox..."
python3 manage.py runserver 0.0.0.0:8000 &
check_command "Erro ao iniciar o NetBox."

# Obtendo o IP do servidor
server_ip=$(hostname -I | awk '{print $1}')
echo "NetBox iniciado. Acesse http://$server_ip:8000 para confirmar."

# Exibindo credenciais de login
echo "Usuários e senhas para login:"
echo "Usuário: admin"
echo "Senha: password"
