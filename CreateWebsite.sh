#!/bin/bash

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <domain> --ssl <yes|no>"
    exit 1
fi

DOMAIN=$1
SSL_FLAG=$2
SSL_ENABLED=$3

# Check if the second argument is --ssl and the third argument is either yes or no
if [ "$SSL_FLAG" != "--ssl" ] || { [ "$SSL_ENABLED" != "yes" ] && [ "$SSL_ENABLED" != "no" ]; }; then
    echo "Usage: $0 <domain> --ssl <yes|no>"
    exit 1
fi

DOMAIN_BASE=$(echo "$DOMAIN" | cut -d. -f1)
DOC_ROOT="/home/$DOMAIN/public_html"
HTTP_CONFIG_FILE="/etc/httpd/conf.d/$DOMAIN.conf"
HTTPS_CONFIG_FILE="/etc/httpd/conf.d/${DOMAIN}_ssl.conf"
LOG_DIR="/var/log/httpd/$DOMAIN"
DEFAULT_CONFIG_FILE="/etc/httpd/conf.d/000default.conf"
PHP_FPM_POOL_FILE="/etc/php-fpm.d/$DOMAIN_BASE.conf"


mkdir -p "$DOC_ROOT"


if ! semanage fcontext -l | grep -F "/home/[^/]+/public_html(/.*)?" > /dev/null; then
    semanage fcontext -a -t httpd_sys_rw_content_t "/home/[^/]+/public_html(/.*)?"
fi
restorecon -RFv "/home/" > /dev/null 2>&1

cat <<EOL > "$DOC_ROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to $DOMAIN!</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            text-align: center;
            margin: 0;
            padding: 0;
            background-color: #f4f4f4;
            color: #333;
        }
        h1 {
            margin-top: 50px;
            font-size: 2em;
        }
    </style>
</head>
<body>
    <h1>Success! The $DOMAIN is working!</h1>
</body>
</html>
EOL

chown -R "apache:apache" "/home/$DOMAIN"
chmod -R 755 "$DOC_ROOT"

cat <<EOL > "$PHP_FPM_POOL_FILE"
[$DOMAIN_BASE]
user = apache
group = apache
listen = /run/php-fpm/$DOMAIN_BASE.sock
listen.owner = apache
listen.group = apache
listen.mode = 0660
pm = dynamic
pm.max_children = 50
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
pm.max_requests = 500
chdir = /
EOL

systemctl reload php-fpm > /dev/null 2>&1

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

mkdir -p /etc/pki/tls/certs
mkdir -p /etc/pki/tls/private
if [ ! -f /etc/pki/tls/certs/localhost.crt ] || [ ! -f /etc/pki/tls/private/localhost.key ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/pki/tls/private/localhost.key -out /etc/pki/tls/certs/localhost.crt -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=localhost"
fi

cat <<EOL > "$HTTPS_CONFIG_FILE"
<VirtualHost *:443>
    ServerAdmin webmaster@$DOMAIN
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN *.$DOMAIN
    DocumentRoot $DOC_ROOT
    ErrorLog $LOG_DIR/ssl_error.log
    CustomLog $LOG_DIR/ssl_access.log combined
    SSLEngine on
    SSLCertificateFile /etc/pki/tls/certs/localhost.crt
    SSLCertificateKeyFile /etc/pki/tls/private/localhost.key

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php-fpm/$DOMAIN_BASE.sock|fcgi://localhost"
    </FilesMatch>

    <Directory "$DOC_ROOT">
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOL

if [ ! -f "$DEFAULT_CONFIG_FILE" ]; then
    cat <<EOL > "$DEFAULT_CONFIG_FILE"
<VirtualHost *:80>
    DocumentRoot /var/www/html
    ErrorLog /var/log/httpd/default_error.log
    CustomLog /var/log/httpd/default_access.log combined
</VirtualHost>

<VirtualHost *:443>
    DocumentRoot /var/www/html
    ErrorLog /var/log/httpd/default_ssl_error.log
    CustomLog /var/log/httpd/default_ssl_access.log combined
    SSLEngine on
    SSLCertificateFile /etc/pki/tls/certs/localhost.crt
    SSLCertificateKeyFile /etc/pki/tls/private/localhost.key
</VirtualHost>
EOL
fi

mkdir -p "$LOG_DIR"
touch "$LOG_DIR/error.log"
touch "$LOG_DIR/access.log"
touch "$LOG_DIR/ssl_error.log"
touch "$LOG_DIR/ssl_access.log"
chown -R "apache:apache" "$LOG_DIR"
chmod -R 755 "$LOG_DIR"

if ! semanage fcontext -l | grep -F "/var/log/httpd/[^/]+/(/.*)?" > /dev/null; then
    semanage fcontext -a -t httpd_sys_rw_content_t "/var/log/httpd/[^/]+/(/.*)?"
fi
restorecon -RFv "/var/log/httpd/" > /dev/null 2>&1

if [ "$SSL_ENABLED" = "yes" ]; then
    systemctl enable --now httpd > /dev/null 2>&1
    if ! systemctl is-active --quiet httpd; then
        exit 1
    fi
fi

systemctl reload httpd > /dev/null 2>&1

echo "Website: $DOMAIN has been created."
