# Configurar e ativar o plugin Zabbix no Grafana
loading_message "Configurando o plugin Zabbix no Grafana" 3
curl -X POST -H "Content-Type: application/json" \
    -d '{
          "name": "Zabbix",
          "type": "datasource",
          "access": "proxy",
          "url": "http://localhost/zabbix",
          "basicAuth": false,
          "jsonData": {
              "zabbixApiUrl": "http://localhost/zabbix/api_jsonrpc.php",
              "username": "Admin",
              "password": "zabbix"
          }
        }' \
    http://admin:admin@localhost:3000/api/datasources || error_message "Erro ao configurar o plugin Zabbix no Grafana"

# Adicionar painel padrão do Zabbix
loading_message "Adicionando painel Zabbix no Grafana" 3
curl -X POST -H "Content-Type: application/json" \
    -d '{
          "dashboard": {
            "title": "Zabbix Dashboard",
            "panels": [
              {
                "type": "graph",
                "title": "Zabbix Server",
                "datasource": "Zabbix"
              }
            ]
          }
        }' \
    http://admin:admin@localhost:3000/api/dashboards/db || error_message "Erro ao adicionar o painel do Zabbix"

# Reiniciar serviços do Zabbix e Grafana
loading_message "Reiniciando serviços do Zabbix e Grafana" 3
systemctl restart zabbix-server zabbix-agent apache2 grafana-server || error_message "Erro ao reiniciar serviços"

# Mensagem final com logo do Zabbix
clear
echo "ZaBBiX"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Acesse o Zabbix na URL: http://$SERVER_IP/zabbix"
echo "Acesse o Grafana na URL: http://$SERVER_IP:3000"
echo "Senha do usuário Zabbix para o banco de dados: $ZABBIX_USER_PASSWORD"
