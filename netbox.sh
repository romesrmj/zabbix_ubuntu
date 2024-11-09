#!/bin/bash

# Função para exibir erros com detalhes
erro() {
    echo "Erro na linha $1: $2"
    echo "Verifique o log de instalação em /var/log/netbox_install.log para mais detalhes."
    exit 1
}

# Função para registrar comandos e erros no log
executar_comando() {
    echo "Executando: $1" | tee -a /var/log/netbox_install.log
    eval "$1" >> /var/log/netbox_install.log 2>&1
    if [ $? -ne 0 ]; then
        erro "$2" "Falha ao executar o comando: $1"
    fi
}

# Inicialização do log de instalação
echo "Iniciando a instalação do Netbox em $(date)" > /var/log/netbox_install.log

# Solicita a senha do usuário do banco de dados
echo "Digite a senha para o usuário 'usrnetbox' no PostgreSQL:"
read -s db_user_password

# Atualiza e atualiza o sistema
executar_comando "sudo apt update && sudo apt upgrade -y" "Falha ao atualizar o sistema."

# Instala o PostgreSQL
executar_comando "sudo apt install -y postgresql" "Falha ao instalar o PostgreSQL."

# Configuração do PostgreSQL
executar_comando "sudo -u postgres psql -c \"CREATE DATABASE dbnetbox;\"" "Falha ao criar banco de dados."
executar_comando "sudo -u postgres psql -c \"CREATE USER usrnetbox WITH PASSWORD '$db_user_password';\"" "Falha ao criar usuário do banco."
executar_comando "sudo -u postgres psql -c \"ALTER DATABASE dbnetbox OWNER TO usrnetbox;\"" "Falha ao atribuir permissões ao banco de dados."

# Instala o Redis
executar_comando "sudo apt install -y redis-server" "Falha ao instalar o Redis."

# Instala o Python3 e pacotes
executar_comando "sudo apt install -y python3 python3-pip python3-venv python3-dev build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev libssl-dev zlib1g-dev" "Falha ao instalar pacotes Python."

# Baixa e extrai o Netbox
executar_comando "cd /tmp && wget https://github.com/netbox-community/netbox/archive/refs/tags/v3.5.8.tar.gz" "Falha ao baixar o Netbox."
executar_comando "sudo tar -xzf v3.5.8.tar.gz -C /opt" "Falha ao extrair o Netbox."
executar_comando "sudo ln -s /opt/netbox-3.5.8/ /opt/netbox" "Falha ao criar link simbólico do Netbox."

# Cria o usuário do Netbox e ajusta permissões
executar_comando "sudo adduser --system --group netbox" "Falha ao criar usuário do sistema Netbox."
executar_comando "sudo chown --recursive netbox /opt/netbox/netbox/media/ /opt/netbox/netbox/reports/ /opt/netbox/netbox/scripts/" "Falha ao ajustar permissões de diretórios."

# Configuração do Netbox
server_ip=$(hostname -I | awk '{print $1}')
executar_comando "cd /opt/netbox/netbox/netbox && sudo cp configuration_example.py configuration.py" "Falha ao copiar arquivo de configuração do Netbox."

# Gera e insere a SECRET_KEY automaticamente
secret_key=$(python3 /opt/netbox/generate_secret_key.py)
sed -i "s/^SECRET_KEY = .*/SECRET_KEY = '$secret_key'/" /opt/netbox/netbox/netbox/configuration.py

# Atualiza configurações com IP do servidor e banco de dados
sed -i "s/^ALLOWED_HOSTS = .*/ALLOWED_HOSTS = ['$server_ip']/" /opt/netbox/netbox/netbox/configuration.py
sed -i "s/'NAME': 'netbox'/'NAME': 'dbnetbox'/" /opt/netbox/netbox/netbox/configuration.py
sed -i "s/'USER': 'netbox'/'USER': 'usrnetbox'/" /opt/netbox/netbox/netbox/configuration.py
sed -i "s/'PASSWORD': ''/'PASSWORD': '$db_user_password'/" /opt/netbox/netbox/netbox/configuration.py

# Instala pacotes opcionais e inicia o script de upgrade do Netbox
executar_comando "echo 'django-storages' >> /opt/netbox/local_requirements.txt" "Falha ao adicionar pacotes opcionais."
executar_comando "sudo /opt/netbox/upgrade.sh" "Falha ao atualizar o Netbox."

# Criação do superusuário para acesso ao Netbox
echo "Digite a senha para o superusuário 'admin' do Netbox:"
read -s superuser_password
echo "Repita a senha:"
read -s superuser_password_confirm

if [ "$superuser_password" != "$superuser_password_confirm" ]; then
    erro "$LINENO" "As senhas do superusuário não coincidem."
fi

executar_comando "source /opt/netbox/venv/bin/activate && python3 /opt/netbox/netbox/manage.py createsuperuser --username admin --email admin@example.com --noinput" "Falha ao criar superusuário do Netbox."
executar_comando "python3 /opt/netbox/netbox/manage.py shell -c \"from django.contrib.auth.models import User; User.objects.filter(username='admin').update(password='$superuser_password')\"" "Falha ao definir a senha do superusuário."

# Configura cron para tarefas de limpeza
executar_comando "sudo ln -s /opt/netbox/contrib/netbox-housekeeping.sh /etc/cron.daily/netbox-housekeeping" "Falha ao configurar cron."

# Configuração do Gunicorn e Apache com SSL
executar_comando "sudo cp /opt/netbox/contrib/gunicorn.py /opt/netbox/gunicorn.py" "Falha ao configurar Gunicorn."
executar_comando "sudo cp -v /opt/netbox/contrib/*.service /etc/systemd/system/ && sudo systemctl daemon-reload" "Falha ao copiar arquivos de serviço do Netbox."
executar_comando "sudo systemctl start netbox netbox-rq && sudo systemctl enable netbox netbox-rq" "Falha ao iniciar os serviços do Netbox."
executar_comando "sudo apt install -y apache2" "Falha ao instalar o Apache."
executar_comando "sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/netbox.key -out /etc/ssl/certs/netbox.crt" "Falha ao gerar certificado SSL."
executar_comando "sudo cp /opt/netbox/contrib/apache.conf /etc/apache2/sites-available/netbox.conf && sudo a2enmod ssl proxy proxy_http headers rewrite && sudo a2ensite netbox && sudo systemctl restart apache2" "Falha ao configurar o Apache."

# Mensagem de conclusão
echo "Instalação do Netbox concluída com sucesso."
echo "Acesse o Netbox em: http://$server_ip:8000"
echo "Detalhes de login:"
echo "Usuário do PostgreSQL: usrnetbox"
echo "Senha do PostgreSQL: $db_user_password"
echo "Superusuário do Netbox: admin"
echo "Senha do superusuário: $superuser_password"
