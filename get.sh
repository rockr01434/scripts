#!/bin/bash

# Import AlmaLinux GPG key
sudo rpm --import https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux

# Install EPEL repository
echo "Installing EPEL repository..."
sudo yum install epel-release -y


# Install unzip
echo "Installing unzip wget nano..."
sudo yum install unzip wget nano -y

# Install OpenLiteSpeed repository
echo "Installing OpenLiteSpeed repository..."
sudo wget -O - https://repo.litespeed.sh | sudo bash
sudo yum install openlitespeed -y

# Install OpenLiteSpeed and PHP
echo "Installing OpenLiteSpeed and PHP..."
sudo yum install openlitespeed lsphp73 lsphp73-common lsphp73-opcache lsphp73-mbstring lsphp73-xml lsphp73-gd lsphp73-curl lsphp73-intl lsphp73-soap lsphp73-xmlrpc lsphp73-ldap lsphp73-bcmath lsphp73-pear lsphp73-devel lsphp73-json -y


# Enable and start OpenLiteSpeed
echo "Enabling and starting OpenLiteSpeed..."
sudo systemctl enable lsws
sudo systemctl start lsws

# Get server IP address
SERVER_IP=$(hostname -I | awk '{print $1}')


ssl_dir="/usr/local/lsws/conf/vhosts/Example"
ssl_key="${ssl_dir}/localhost.key"
ssl_cert="${ssl_dir}/localhost.crt"

if [ ! -f "$ssl_key" ] || [ ! -f "$ssl_cert" ]; then
	openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
		-subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=localhost" \
		-keyout "$ssl_key" -out "$ssl_cert" > /dev/null 2>&1
	chown -R lsadm:lsadm /usr/local/lsws/
fi

# Create OpenLiteSpeed configuration for PHP
OLS_CONF="/usr/local/lsws/conf/httpd_config.conf"

CONTENT="
listener Default {
  address                 *:80
  secure                  0
}

listener SSL {
  address                 *:443
  secure                  1
  keyFile                 $ssl_key
  certFile                $ssl_cert
  certChain               1
}
"

if [ -f "$OLS_CONF" ]; then
  sed -i '/listener Default{/,/}/d' "$OLS_CONF"
  sed -i '/listener Default {/,/}/d' "$OLS_CONF"
  sed -i '/listener SSL {/,/}/d' "$OLS_CONF"
  echo "$CONTENT" >> "$OLS_CONF"
  echo "Listener ports 80 & 443 added to $OLS_CONF"
fi

chown -R lsadm:lsadm /usr/local/lsws/

# Enable and start OpenLiteSpeed
echo "restarting OpenLiteSpeed..."
sudo systemctl restart lsws



# Install Certbot and the OpenLiteSpeed plugin for Certbot
echo "Installing Certbot and OpenLiteSpeed plugin..."
sudo yum install certbot python3-certbot-nginx -y

# Wget website create script
wget -O /usr/local/bin/star https://raw.githubusercontent.com/rockr01434/scripts/main/manage.sh > /dev/null 2>&1
chmod +x /usr/local/bin/star > /dev/null 2>&1


# Install File Browser
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

# Configure File Browser service
cat <<EOL > "/etc/systemd/system/filebrowser.service"
[Unit]
Description=File Browser
After=network.target

[Service]
User=nobody
ExecStart=/usr/local/bin/filebrowser -a $SERVER_IP -r /home --database /var/lib/filebrowser/filebrowser.db -p 9999
Restart=always
RestartSec=5
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOL

sudo mkdir -p /etc/filebrowser /var/lib/filebrowser
sudo chown -R nobody:nobody /var/lib/filebrowser
sudo chown nobody:nobody /usr/local/bin/filebrowser

sudo semanage fcontext -a -t bin_t "/usr/local/bin/filebrowser(/.*)?"
sudo restorecon -R /usr/local/bin/filebrowser

sudo yum install policycoreutils-python-utils -y
sudo semanage port -a -t http_port_t -p tcp 9999

mv /var/lib/filebrowser/filebrowser.db /var/lib/filebrowser/filebrowser.db.bak

sudo systemctl daemon-reload
sudo systemctl enable filebrowser
sudo systemctl start filebrowser

printf "\n\n\033[0;32mInstallation completed. OpenLiteSpeed, PHP 7.3, Python 3, Certbot, and unzip have been installed and configured.\033[0m\n\n\n"
printf "\033[0;32mYour File Manager Link: http://$SERVER_IP:9999\033[0m\n"
printf "\033[0;32mYour File Manager User: admin\033[0m\n"
printf "\033[0;32mYour File Manager Pass: admin\033[0m\n\n\n"
