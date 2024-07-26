#!/bin/bash

# Ensure exactly two arguments are provided
if [ "$#" -ne 2 ]; then
	echo "Usage: $0 <domain> --ssl <yes|no>"
	exit 1
fi

DOMAIN=$1
SSL_FLAG=$2

# Check if the second argument is --ssl and the third argument is either yes or no
if [ "$SSL_FLAG" != "--ssl yes" ] && [ "$SSL_FLAG" != "--ssl no" ]; then
	echo "Usage: $0 <domain> --ssl <yes|no>"
	exit 1
fi

SSL_ENABLED=${SSL_FLAG#--ssl }

DOMAIN_BASE=$(echo "$DOMAIN" | cut -d. -f1)
DOC_ROOT="/home/$DOMAIN_BASE/public_html"
HTTP_CONFIG_FILE="/etc/httpd/conf.d/$DOMAIN.conf"
HTTPS_CONFIG_FILE="/etc/httpd/conf.d/${DOMAIN}_ssl.conf"
LOG_DIR="/var/log/httpd/$DOMAIN"
DEFAULT_CONFIG_FILE="/etc/httpd/conf.d/default.conf"
PHP_FPM_POOL_FILE="/etc/php-fpm.d/$DOMAIN_BASE.conf"

# Create a system user for the domain without creating a home directory
USER=$DOMAIN_BASE
if id "$USER" &>/dev/null; then
	# User exists
	:
else
	useradd -r -s /sbin/nologin --no-create-home $USER
fi

# Create the document root
mkdir -p "$DOC_ROOT"
chown -R "$USER:$USER" "$DOC_ROOT"
chmod -R 755 "$DOC_ROOT"

# Apply SELinux context to the document root
semanage fcontext -a -t httpd_sys_rw_content_t "/home/$DOMAIN_BASE/public_html(/.*)?"
restorecon -R "$DOC_ROOT"
chcon -R -t httpd_sys_rw_content_t $DOC_ROOT

# Create a simple index.html file
cat <<EOL > "$DOC_ROOT/index.html"
<html>
	<head>
		<title>Welcome to $DOMAIN!</title>
	</head>
	<body>
		<h1>Success! The $DOMAIN virtual host is working!</h1>
	</body>
</html>
EOL

# Create the PHP-FPM pool configuration file
cat <<EOL > "$PHP_FPM_POOL_FILE"
[$DOMAIN_BASE]
user = $USER
group = $USER
listen = /run/php-fpm/$DOMAIN_BASE.sock
listen.owner = $USER
listen.group = apache
listen.mode = 0660
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
chdir = /
EOL

# Restart PHP-FPM service
systemctl restart php-fpm

# Create the HTTP virtual host configuration file
cat <<EOL > "$HTTP_CONFIG_FILE"
<VirtualHost *:80>
	ServerAdmin webmaster@$DOMAIN
	ServerName $DOMAIN
	ServerAlias www.$DOMAIN *.$DOMAIN
	DocumentRoot $DOC_ROOT
	ErrorLog $LOG_DIR/error.log
	CustomLog $LOG_DIR/access.log combined

	<FilesMatch \.php$>
		SetHandler "proxy:unix:/run/php-fpm/$DOMAIN_BASE.sock|fcgi://localhost"
	</FilesMatch>

	<Directory "$DOC_ROOT">
		AllowOverride None
		Require all granted
	</Directory>
</VirtualHost>
EOL

# Generate dummy SSL certificates if SSL is enabled
mkdir -p /etc/pki/tls/certs
mkdir -p /etc/pki/tls/private
if [ ! -f /etc/pki/tls/certs/localhost.crt ] || [ ! -f /etc/pki/tls/private/localhost.key ]; then
	openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/pki/tls/private/localhost.key -out /etc/pki/tls/certs/localhost.crt -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=localhost"
fi

# Create the HTTPS virtual host configuration file with a dummy certificate
cat <<EOL > "$HTTPS_CONFIG_FILE"
<VirtualHost *:443>
	ServerAdmin webmaster@$DOMAIN
	ServerName $DOMAIN
	ServerAlias www.$DOMAIN *.$DOMAIN
	DocumentRoot $DOC_ROOT
	ErrorLog $LOG_DIR/error.log
	CustomLog $LOG_DIR/access.log combined

	# Dummy SSL configuration
	SSLEngine on
	SSLCertificateFile /etc/pki/tls/certs/localhost.crt
	SSLCertificateKeyFile /etc/pki/tls/private/localhost.key
	SSLProtocol all -SSLv2 -SSLv3

	<FilesMatch \.php$>
		SetHandler "proxy:unix:/run/php-fpm/$DOMAIN_BASE.sock|fcgi://localhost"
	</FilesMatch>

	<Directory "$DOC_ROOT">
		AllowOverride None
		Require all granted
	</Directory>
</VirtualHost>
EOL

# Check if the configuration file already exists
if [ ! -f "$DEFAULT_CONFIG_FILE" ]; then
	# Create default virtual host to handle server IP requests
	cat <<EOL > "$DEFAULT_CONFIG_FILE"
<VirtualHost *:80>
	ServerAdmin webmaster@localhost
	DocumentRoot /var/www/html
	ServerName 127.0.0.1
	ServerAlias localhost

	ErrorLog /var/log/httpd/default_error.log
	CustomLog /var/log/httpd/default_access.log combined

	<Directory "/var/www/html">
		AllowOverride None
		Require all granted
	</Directory>
</VirtualHost>
EOL
fi

# Create log directory and files
mkdir -p "$LOG_DIR"
touch "$LOG_DIR/error.log"
touch "$LOG_DIR/access.log"
chown -R "$USER:$USER" "$LOG_DIR"

# Apply SELinux context to the log directory
semanage fcontext -a -t httpd_log_t "/var/log/httpd/$DOMAIN(/.*)?"
restorecon -R "$LOG_DIR"

# Install and configure SSL if needed
if [ "$SSL_ENABLED" = "yes" ]; then
	# Install Certbot if not already installed
	if ! command -v certbot &> /dev/null; then
		echo "Certbot not found. Installing Certbot..."
		dnf install -y epel-release
		dnf install -y certbot python3-certbot-apache
	fi

	# Obtain and install the SSL certificate
	echo "Obtaining SSL certificate for $DOMAIN..."
	certbot --apache -d $DOMAIN --non-interactive --agree-tos --email webmaster@$DOMAIN --no-redirect

	if [ $? -eq 0 ]; then
		echo "SSL certificate successfully installed for $DOMAIN."
		# Reload Apache to apply SSL certificate
		systemctl reload httpd
	else
		echo "Failed to obtain SSL certificate."
		exit 1
	fi
fi

# Check Apache configuration and restart Apache
apachectl configtest > /dev/null 2>&1
if [ $? -eq 0 ]; then
	apachectl graceful
	echo "Website: $DOMAIN has been created."
else
	echo "Apache configuration test failed."
	exit 1
fi
