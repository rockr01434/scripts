#!/bin/bash

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

DOMAIN=$1
DOMAIN_BASE=$(echo "$DOMAIN" | cut -d. -f1)
DOC_ROOT="/home/$DOMAIN/public_html"
HTTP_CONFIG_FILE="/etc/httpd/conf.d/$DOMAIN.conf"
HTTPS_CONFIG_FILE="/etc/httpd/conf.d/${DOMAIN}_ssl.conf"
LOG_DIR="/var/log/httpd/$DOMAIN"
PHP_FPM_POOL_FILE="/etc/php-fpm.d/$DOMAIN_BASE.conf"

# Stop Apache and PHP-FPM services
systemctl stop httpd
systemctl stop php-fpm

# Remove Apache configuration files
rm -f "$HTTP_CONFIG_FILE"
rm -f "$HTTPS_CONFIG_FILE"

# Remove PHP-FPM pool configuration file
rm -f "$PHP_FPM_POOL_FILE"

# Remove log directory
rm -rf "$LOG_DIR"

# Remove the document root directory
rm -rf "$DOC_ROOT"


# Start Apache and PHP-FPM services
systemctl start httpd
systemctl start php-fpm

echo "Website: $DOMAIN has been deleted."
