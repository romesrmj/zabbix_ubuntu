# zabbix_ubuntu
instalação automatica do zabbix 6.04 + Grafana

# Baixe o pacote

bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/zabbix_auto.sh)

# Novo pacote de deploy
bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/zabbix_deploy.sh)

#Permissão no arquivo
chmod +x zabbix_auto.sh

#Execute a aplicação
./zabbix_auto.sh

