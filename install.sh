#!/bin/bash

sudo rpm --import https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux

# Install EPEL repository
echo "Installing EPEL repository..."
sudo dnf install epel-release -y

# Install unzip
echo "Installing unzip wget nano..."
sudo dnf install unzip wget nano -y


# Install Apache
echo "Installing Apache..."
sudo dnf install httpd -y



# Enable Remi repository
echo "Enabling Remi repository..."
sudo dnf install https://rpms.remirepo.net/enterprise/remi-release-8.rpm -y
sudo dnf module reset php -y
sudo dnf module enable php:remi-7.4 -y


# Install PHP 7.4 and related packages
echo "Installing PHP 7.4 and related packages..."
sudo dnf install php php-cli php-common php-fpm php-json php-opcache php-mbstring php-xml php-zip php-gd php-curl php-intl php-soap php-xmlrpc php-ldap php-bcmath php-pear php-devel php-embedded php-dba php-pdo php-gettext php-readline -y


# Install Python 3 perl
echo "Installing Python 3 & perl..."
sudo dnf install python3 perl -y


# Enable and start Apache
echo "Enabling and starting Apache..."
sudo systemctl enable httpd
sudo systemctl start httpd

# Configure Apache to use PHP
echo "<?php phpinfo(); ?>" | sudo tee /var/www/html/info.php > /dev/null

# Install Certbot and the Apache plugin for Certbot
echo "Installing Certbot and Apache plugin..."
sudo dnf install certbot python3-certbot-apache -y


# Enable and start PHP-FPM
echo "Enabling and starting PHP-FPM..."
sudo systemctl enable php-fpm
sudo systemctl start php-fpm


# Wget website create script
wget -O /usr/local/bin/CreateWebsite https://raw.githubusercontent.com/rockr01434/scripts/main/CreateWebsite.sh > /dev/null 2>&1
chmod +x /usr/local/bin/CreateWebsite > /dev/null 2>&1

# Wget website delete script
wget -O /usr/local/bin/DeleteWebsite https://raw.githubusercontent.com/rockr01434/scripts/main/DeleteWebsite.sh > /dev/null 2>&1
chmod +x /usr/local/bin/DeleteWebsite > /dev/null 2>&1

wget -O /usr/local/bin/MultiWebsite https://raw.githubusercontent.com/rockr01434/scripts/main/MultiWebsite.sh > /dev/null 2>&1
chmod +x /usr/local/bin/MultiWebsite > /dev/null 2>&1


# Path to the Apache main configuration file
APACHE_CONF="/etc/httpd/conf/httpd.conf"

# Backup the original configuration file
cp "$APACHE_CONF" "$APACHE_CONF.bak"

# Update or add ServerName directive
if grep -q '^#.*ServerName' "$APACHE_CONF"; then
    sed -i '/^#.*ServerName/s/^# *ServerName.*/ServerName localhost/' "$APACHE_CONF"
elif ! grep -q '^ServerName ' "$APACHE_CONF"; then
    echo "ServerName localhost" >> "$APACHE_CONF"
fi

# Add MPM Event Module Configuration
MPM_CONF="/etc/httpd/conf.modules.d/00-mpm.conf"
MPM_EVENT_CONF="/etc/httpd/conf.modules.d/mpm_event.conf"

# Check and add settings to 00-mpm.conf
if ! grep -q "<IfModule mpm_event_module>" "$MPM_CONF"; then
    cat <<EOL >> "$MPM_CONF"
<IfModule mpm_event_module>
    StartServers             5
    MinSpareThreads          50
    MaxSpareThreads          150
    ThreadLimit              128
    ThreadsPerChild          50
    MaxRequestWorkers        800
    MaxConnectionsPerChild   2000
</IfModule>
EOL
fi

# Check and add settings to mpm_event.conf
if ! grep -q "<IfModule mpm_event_module>" "$MPM_EVENT_CONF"; then
    cat <<EOL >> "$MPM_EVENT_CONF"
<IfModule mpm_event_module>
    StartServers             5
    MinSpareThreads          50
    MaxSpareThreads          150
    ThreadLimit              128
    ThreadsPerChild          50
    MaxRequestWorkers        800
    MaxConnectionsPerChild   2000
</IfModule>
EOL
fi

# Restart Apache to apply changes
echo "Restarting Apache..."
sudo systemctl restart httpd

# Get server IP address
SERVER_IP=$(hostname -I | awk '{print $1}')

curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

cat <<EOL > "/etc/systemd/system/filebrowser.service"
[Unit]
Description=File Browser
After=network.target

[Service]
User=apache
ExecStart=/usr/local/bin/filebrowser -a $SERVER_IP -r /home --database /var/lib/filebrowser/filebrowser.db -p 9999
Restart=always
RestartSec=5
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOL

sudo mkdir -p /etc/filebrowser /var/lib/filebrowser
sudo chown -R apache:apache /var/lib/filebrowser
sudo chown apache:apache /usr/local/bin/filebrowser


sudo semanage fcontext -a -t bin_t "/usr/local/bin/filebrowser(/.*)?"
sudo restorecon -R /usr/local/bin/filebrowser

sudo dnf install policycoreutils-python-utils -y
sudo semanage port -a -t http_port_t -p tcp 9999

mv /var/lib/filebrowser/filebrowser.db /var/lib/filebrowser/filebrowser.db.bak

systemctl daemon-reload
systemctl enable filebrowser
systemctl start filebrowser



printf "\n\n\033[0;32mInstallation completed. Apache, PHP 7.4, Python 3, Certbot, and unzip have been installed and configured.\033[0m\n\n\n"
printf "\033[0;32mYour File Manager Link: http://$SERVER_IP:9999\033[0m\n"
printf "\033[0;32mYour File Manager User: admin\033[0m\n"
printf "\033[0;32mYour File Manager Pass: admin\033[0m\n\n\n"
