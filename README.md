# zabbix_ubuntu + Netbox
instalação automatica do zabbix 7Lts + Grafana V 4.5.6

# Baixe o pacote
## New Verson:
bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/zbx_ubt2404.sh)

bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/zbx_ubt2404_v2.sh)

bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/zbx_ubt-2404.sh)

# Deploy Netbox
bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/netbox.sh)

#Permissão no arquivo
chmod +x zabbix_auto.sh

#Execute a aplicação
./zabbix_auto.sh

