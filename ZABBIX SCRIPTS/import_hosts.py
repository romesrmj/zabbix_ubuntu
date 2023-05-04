import csv
from zabbix_api import ZabbixAPI

# Configurações de conexão do Zabbix
zabbix_url = "http://localhost/zabbix"
zabbix_user = "admin"
zabbix_password = "password"

# Cria uma conexão com o Zabbix API
zabbix_api = ZabbixAPI(url=zabbix_url, user=zabbix_user, password=zabbix_password)

# Abre o arquivo CSV
with open('hosts.csv', mode='r') as csv_file:
    csv_reader = csv.DictReader(csv_file)
    for row in csv_reader:
        # Obtém o nome do grupo de host a partir do arquivo CSV
        group_name = row['group_name']

        # Verifica se o grupo de host já existe no Zabbix, senão cria um novo grupo de host
        group = zabbix_api.hostgroup.get(filter={'name': group_name})
        if not group:
            group_create_params = {'name': group_name}
            group = zabbix_api.hostgroup.create(group_create_params)[0]['groupids'][0]

        # Obtém o nome do host e o endereço IP a partir do arquivo CSV
        host_name = row['host_name']
        host_ip = row['host_ip']

        # Cria o novo host no Zabbix e o atribui ao grupo de host correspondente
        host_create_params = {
            'host': host_name,
            'interfaces': [{'type': 1, 'main': 1, 'useip': 1, 'ip': host_ip, 'dns': '', 'port': '10050'}],
            'groups': [{'groupid': group}]
        }
        zabbix_api.host.create(host_create_params)
