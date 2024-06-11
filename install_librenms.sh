#!/bin/bash

# Prompt user for database password
read -sp 'Enter the LibreNMS database user password: ' DB_PASSWORD
echo
read -sp 'Enter the MariaDB root password: ' ROOT_PASSWORD
echo

# Update system and install required packages
apt update
apt install -y apt-transport-https lsb-release ca-certificates wget acl curl fping git graphviz imagemagick mariadb-client mariadb-server mtr-tiny nginx-full nmap php8.2-cli php8.2-curl php8.2-fpm php8.2-gd php8.2-gmp php8.2-mbstring php8.2-mysql php8.2-snmp php8.2-xml php8.2-zip python3-dotenv python3-pymysql python3-redis python3-setuptools python3-pip rrdtool snmp snmpd unzip whois

# Add librenms user
useradd librenms -d /opt/librenms -M -r -s "$(which bash)"

# Download LibreNMS
cd /opt
git clone https://github.com/librenms/librenms.git

# Set permissions
chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/

# Install PHP dependencies
su - librenms -c "/opt/librenms/scripts/composer_wrapper.php install --no-dev"

# Set timezone in PHP configuration
PHP_TIMEZONE="Europe/Lisbon"
sed -i "s|;date.timezone =|date.timezone = $PHP_TIMEZONE|g" /etc/php/8.2/fpm/php.ini
sed -i "s|;date.timezone =|date.timezone = $PHP_TIMEZONE|g" /etc/php/8.2/cli/php.ini

# Set system timezone
timedatectl set-timezone Etc/UTC

# Configure MariaDB
cat <<EOL >> /etc/mysql/mariadb.conf.d/50-server.cnf
[mysqld]
innodb_file_per_table=1
lower_case_table_names=0
EOL

systemctl enable mariadb
systemctl restart mariadb

# Setup MariaDB database and user
mysql -u root -p${ROOT_PASSWORD} <<EOF
CREATE DATABASE librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'librenms'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
EOF

# Configure PHP-FPM for LibreNMS
cp /etc/php/8.2/fpm/pool.d/www.conf /etc/php/8.2/fpm/pool.d/librenms.conf
sed -i 's/\[www\]/\[librenms\]/' /etc/php/8.2/fpm/pool.d/librenms.conf
sed -i 's/user = www-data/user = librenms/' /etc/php/8.2/fpm/pool.d/librenms.conf
sed -i 's/group = www-data/group = librenms/' /etc/php/8.2/fpm/pool.d/librenms.conf
sed -i 's|listen = /run/php/php8.2-fpm.sock|listen = /run/php-fpm-librenms.sock|' /etc/php/8.2/fpm/pool.d/librenms.conf

rm /etc/php/8.2/fpm/pool.d/www.conf

# Configure NGINX for LibreNMS
cat <<EOL > /etc/nginx/sites-enabled/librenms.vhost
server {
 listen      80;
 server_name librenms.example.com;
 root        /opt/librenms/html;
 index       index.php;

 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;

 location / {
  try_files \$uri \$uri/ /index.php?\$query_string;
 }
 location ~ [^/]\.php(/|\$) {
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_split_path_info ^(.+\.php)(/.+)\$;
  include fastcgi.conf;
 }
 location ~ /\.(?!well-known).* {
  deny all;
 }
}
EOL

rm /etc/nginx/sites-enabled/default
systemctl reload nginx
systemctl restart php8.2-fpm

# Enable lnms command completion
ln -s /opt/librenms/lnms /usr/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/

# Configure snmpd
cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
sed -i 's/RANDOMSTRINGGOESHERE/your_community_string/' /etc/snmp/snmpd.conf

curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro

systemctl enable snmpd
systemctl restart snmpd

# Setup Cron job for LibreNMS
cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms

# Enable LibreNMS scheduler
cp /opt/librenms/dist/librenms-scheduler.service /etc/systemd/system/
cp /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/

systemctl enable librenms-scheduler.timer
systemctl start librenms-scheduler.timer

# Copy logrotate config for LibreNMS
cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms

echo "Installation and configuration of LibreNMS is complete."
echo "Please follow the web installer instructions to finalize the setup."
