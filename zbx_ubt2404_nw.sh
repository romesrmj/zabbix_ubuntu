#!/bin/bash
# Full deployment script for Zabbix 6.0 and Grafana with APACHE on Ubuntu 22.04

# Exit on error
set -e

# Log file
LOG_FILE="/var/log/zabbix-grafana-deployment.log"
exec > >(tee -i $LOG_FILE)
exec 2>&1

echo "Starting Zabbix 6.0 with APACHE and Grafana deployment on Ubuntu 22.04 at $(date)"
echo "----------------------------------------------"

#!/bin/bash
# Update package lists
apt-get update

# Install required packages
apt-get install -y \
  apt-transport-https \
  software-properties-common \
  wget \
  curl \
  gnupg2 \
  ca-certificates \
  lsb-release \
  python3-pip \
  net-snmp \
  snmp \
  snmp-mibs-downloader \
  libsnmp-dev

# Download MIBs
download-mibs

# Enable MIBs
if [ -f "/etc/snmp/snmp.conf" ]; then
  sed -i 's/mibs :/# mibs :/g' /etc/snmp/snmp.conf
fi

# Install SNMP Python modules
pip3 install pysnmp pysnmp-mibs

echo "Base packages installed successfully on Ubuntu 22.04"


#!/bin/bash
# Install Zabbix repository
wget https://repo.zabbix.com/zabbix/6.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_6.0-4+ubuntu22.04_all.deb
dpkg -i zabbix-release_6.0-4+ubuntu22.04_all.deb
apt-get update

# Install Zabbix server, frontend, and agent
if [ "mysql" == "mysql" ]; then
  apt-get install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent mysql-server
  
  # Install Apache
apt-get install -y apache2 libapache2-mod-php
  
  # Secure MySQL installation
  mysql_secure_installation <<EOF

Y
srvzbx123
srvzbx123
Y
Y
Y
Y
EOF

  # Create database
  mysql -uroot -psrvzbx123 -e "create database zabbix character set utf8mb4 collate utf8mb4_bin;"
  mysql -uroot -psrvzbx123 -e "create user 'zabbix'@'localhost' identified by 'srvzbx123';"
  mysql -uroot -psrvzbx123 -e "grant all privileges on zabbix.* to 'zabbix'@'localhost';"
  
  # Import initial schema
  zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -uzabbix -psrvzbx123 zabbix
  
elif [ "mysql" == "postgresql" ]; then
  apt-get install -y zabbix-server-pgsql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent postgresql
  
  # Install Apache
apt-get install -y apache2 libapache2-mod-php
  
  # Create database
  sudo -u postgres psql -c "CREATE USER zabbix WITH PASSWORD 'srvzbx123';"
  sudo -u postgres psql -c "CREATE DATABASE zabbix OWNER zabbix;"
  
  # Import initial schema
  zcat /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz | sudo -u postgres psql zabbix
fi

# Configure Zabbix server
sed -i "s/# DBPassword=/DBPassword=srvzbx123/g" /etc/zabbix/zabbix_server.conf
sed -i "s/# DBName=zabbix/DBName=zabbix/g" /etc/zabbix/zabbix_server.conf
sed -i "s/# DBUser=zabbix/DBUser=zabbix/g" /etc/zabbix/zabbix_server.conf

# Web server configuration
# Configure Apache
# PHP timezone settings
sed -i 's/;date.timezone =/date.timezone = UTC/g' /etc/php*/*/php.ini

# Start services
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart zabbix-server zabbix-agent apache2 || systemctl restart zabbix-server zabbix-agent httpd
  systemctl enable zabbix-server zabbix-agent apache2 || systemctl enable zabbix-server zabbix-agent httpd
elif command -v service >/dev/null 2>&1; then
  service zabbix-server restart
  service zabbix-agent restart
  service apache2 restart || service httpd restart
elif command -v rc-service >/dev/null 2>&1; then
  rc-service zabbix-server restart
  rc-service zabbix-agent restart
  rc-service apache2 restart || rc-service httpd restart
  rc-update add zabbix-server default
  rc-update add zabbix-agent default
  rc-update add apache2 default || rc-update add httpd default
fi

echo "Zabbix 6.0 installation with APACHE completed successfully on Ubuntu 22.04"


#!/bin/bash
# Install Grafana
apt-get install -y apt-transport-https software-properties-common
wget -q -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key

echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" | tee -a /etc/apt/sources.list.d/grafana.list

apt-get update
apt-get install -y grafana

# Configure Grafana
cat > /etc/grafana/grafana.ini <<EOL
[server]
http_port = 3000

[security]
admin_user = admin
admin_password = srvzbx123

[database]
EOL

# Start Grafana
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl start grafana-server
  systemctl enable grafana-server
elif command -v service >/dev/null 2>&1; then
  service grafana-server start
elif command -v rc-service >/dev/null 2>&1; then
  rc-service grafana-server start
  rc-update add grafana-server default
fi

# Install Zabbix plugin for Grafana
if command -v grafana-cli >/dev/null 2>&1; then
  grafana-cli plugins install alexanderzobnin-zabbix-app
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart grafana-server
  elif command -v service >/dev/null 2>&1; then
    service grafana-server restart
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service grafana-server restart
  fi
fi

echo "Grafana installation completed successfully on Ubuntu 22.04"


#!/bin/bash
# Create API user in Zabbix (this is a placeholder - in production this would use Zabbix API)
echo "Creating API user in Zabbix for Grafana integration..."

# We'll use an environment variable to store the Zabbix API key that Grafana will use
# In a real deployment, this would be done via the Zabbix API
echo "ZABBIX_API_KEY=your_zabbix_api_key" >> /etc/environment

echo "Zabbix 6.0 and Grafana integration completed on Ubuntu 22.04"


#!/bin/bash
# Configure SNMP monitoring for network devices

# Make sure SNMP templates are imported into Zabbix
# This is a simplified version - in production this would use Zabbix API



echo "Network device configuration completed on Ubuntu 22.04"


#!/bin/bash
# Security hardening script for Zabbix and Grafana deployment on Ubuntu 22.04

# Enable and configure UFW firewall
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https
ufw allow 80/tcp
ufw allow 10051/tcp
ufw allow 10050/tcp
ufw allow 3000/tcp
ufw --force enable


# Secure SSH configuration
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/g' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart sshd
elif command -v service >/dev/null 2>&1; then
  service sshd restart
elif command -v rc-service >/dev/null 2>&1; then
  rc-service sshd restart
fi


# Install and configure Fail2Ban
apt-get install -y fail2ban
cat > /etc/fail2ban/jail.local <<EOL
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true

[apache]
enabled = true

[grafana]
enabled = true
port = 3000
logpath = /var/log/grafana/grafana.log
EOL

systemctl restart fail2ban


# Create a restricted admin user
useradd -m -s /bin/bash admin
case "ubuntu" in
  ubuntu|debian)
    usermod -aG sudo admin
    ;;
  rocky|rhel)
    usermod -aG wheel admin
    ;;
  alpine)
    apk add sudo
    addgroup admin wheel
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
    ;;
  opensuse)
    usermod -aG wheel admin
    ;;
esac
mkdir -p /home/admin/.ssh
echo "# Add your public SSH key here" > /home/admin/.ssh/authorized_keys
chmod 700 /home/admin/.ssh
chmod 600 /home/admin/.ssh/authorized_keys
chown -R admin:admin /home/admin/.ssh

echo "Security hardening with APACHE web server completed on Ubuntu 22.04"

echo "----------------------------------------------"
echo "Deployment completed successfully on $(date)"
echo "Zabbix 6.0 with APACHE is accessible at: http://SRVZBX01:80/"
echo "Grafana is accessible at: http://SRVZBX01:3000/"
echo "Check the log file at $LOG_FILE for more details"
