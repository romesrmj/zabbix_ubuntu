# zabbix_ubuntu + Netbox
instalação automatica do zabbix 7Lts + Grafana V 4.5.6

# Baixe o pacote
## New Verson:
bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/zbx_ubt2404_nw.sh)

bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/zbx_ubt2404.sh)

bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/zbx_ubt2404_v2.sh)

bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/zbx_ubt-2404.sh)

Zabbix 7, Apache, Grafana -- ubuntu server 24.04

#INSTALL
bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/zbx7.sh)

#ROOLBACK
bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/roolback_zbx7.sh)

# Deploy Netbox
bash <(wget -qO- https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/main/netbox.sh)

# Deploy Docker + Zabbix Proxy Enterprise
curl -fsSL https://raw.githubusercontent.com/romesrmj/zabbix_ubuntu/refs/heads/main/zabbix-proxy-enterprise.sh -o /tmp/zabbix-proxy-enterprise.sh && sudo bash /tmp/zabbix-proxy-enterprise.sh

#Permissão no arquivo
chmod +x zabbix_auto.sh

#Execute a aplicação
./zabbix_auto.sh

