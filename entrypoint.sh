#!/bin/bash
set -Eeuo pipefail

ENV_FILE="/var/www/app.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: .env file not found"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

# ============================================================
# DevOpsStudy - Apache + Let's Encrypt Automatic SSL
# Domains:
#   devopsstudy.in
#   www.devopsstudy.in
# ============================================================

: "${FQDN:?ERROR: FQDN must be configured in .env}"

WWW_DOMAIN="www.${FQDN}"
EMAIL="${CERTBOT_EMAIL:-admin@${FQDN}}"

WEBROOT="/var/www/certbot"
CERT_DIR="/etc/letsencrypt/live/${FQDN}"
FULLCHAIN="${CERT_DIR}/fullchain.pem"
PRIVKEY="${CERT_DIR}/privkey.pem"

HTTP_CONFIG="/etc/apache2/sites-available/000-default.conf"
HTTPS_CONFIG="/etc/apache2/sites-available/001-https.conf"

echo "============================================================"
echo " Starting DevOpsStudy"
echo " Domain: ${FQDN}"
echo " WWW:    ${WWW_DOMAIN}"
echo " Email:  ${EMAIL}"
echo "============================================================"

# ------------------------------------------------------------
# 1. Prepare directories and Apache modules
# ------------------------------------------------------------

mkdir -p "${WEBROOT}/.well-known/acme-challenge"
mkdir -p /etc/letsencrypt

a2enmod ssl rewrite

# ------------------------------------------------------------
# 2. Configure HTTP virtual host
#    HTTP is required for Let's Encrypt HTTP-01 validation.
# ------------------------------------------------------------

write_http_config() {
    cat > "${HTTP_CONFIG}" <<EOF
<VirtualHost *:80>
    ServerName ${FQDN}
    ServerAlias ${WWW_DOMAIN}

    DocumentRoot /var/www/html

    Alias /.well-known/acme-challenge/ ${WEBROOT}/.well-known/acme-challenge/

    <Directory ${WEBROOT}/.well-known/acme-challenge/>
        Options None
        AllowOverride None
        Require all granted
    </Directory>

    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    RewriteEngine On

    # Allow Let's Encrypt validation over HTTP.
    RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/

    # Redirect to HTTPS only after the certificate exists.
    RewriteCond ${FULLCHAIN} -f
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>
EOF
}

# ------------------------------------------------------------
# 3. Configure HTTPS virtual host
# ------------------------------------------------------------

write_https_config() {
    cat > "${HTTPS_CONFIG}" <<EOF
<VirtualHost *:443>
    ServerName ${FQDN}
    ServerAlias ${WWW_DOMAIN}

    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile ${FULLCHAIN}
    SSLCertificateKeyFile ${PRIVKEY}

    <Directory /var/www/html>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

    a2ensite 001-https >/dev/null
}

# ------------------------------------------------------------
# 4. Start Apache on HTTP
# ------------------------------------------------------------

write_http_config

# Never enable HTTPS without a valid certificate and key.
if [[ -s "${FULLCHAIN}" && -s "${PRIVKEY}" ]]; then
    write_https_config
else
    a2dissite 001-https >/dev/null 2>&1 || true
fi

apache2ctl configtest

apache2ctl -DFOREGROUND &
APACHE_PID=$!

shutdown() {
    echo "Stopping Apache and renewal loop..."

    kill -TERM "${APACHE_PID}" 2>/dev/null || true
    wait "${APACHE_PID}" 2>/dev/null || true
}

trap shutdown SIGTERM SIGINT

# Wait for the Apache HTTP listener.
HTTP_READY=false

for i in $(seq 1 30); do
    if ! kill -0 "${APACHE_PID}" 2>/dev/null; then
        echo "ERROR: Apache exited unexpectedly."
        exit 1
    fi

    if (echo > /dev/tcp/127.0.0.1/80) >/dev/null 2>&1; then
        HTTP_READY=true
        break
    fi

    sleep 1
done

if [[ "${HTTP_READY}" != true ]]; then
    echo "ERROR: Apache did not start listening on port 80."
    exit 1
fi

# ------------------------------------------------------------
# 5. Obtain initial Let's Encrypt certificate
# ------------------------------------------------------------

while [[ ! -s "${FULLCHAIN}" || ! -s "${PRIVKEY}" ]]; do
    echo "Requesting SSL certificate for:"
    echo "  ${FQDN}"
    echo "  ${WWW_DOMAIN}"

    if certbot certonly \
        --webroot \
        --webroot-path "${WEBROOT}" \
        --cert-name "${FQDN}" \
        -d "${FQDN}" \
        -d "${WWW_DOMAIN}" \
        --email "${EMAIL}" \
        --agree-tos \
        --non-interactive; then

        if [[ -s "${FULLCHAIN}" && -s "${PRIVKEY}" ]]; then
            echo "SSL certificate obtained successfully."
            break
        fi
    fi

    echo "Certificate issuance failed."
    echo "Check DNS, firewall ports 80/443, and Certbot logs."
    echo "Retrying in 5 minutes..."

    sleep 300

    if ! kill -0 "${APACHE_PID}" 2>/dev/null; then
        echo "ERROR: Apache exited while waiting for a certificate."
        exit 1
    fi
done

# ------------------------------------------------------------
# 6. Enable HTTPS and HTTP-to-HTTPS redirect
# ------------------------------------------------------------

write_http_config
write_https_config

apache2ctl configtest
apache2ctl graceful

echo "============================================================"
echo " SSL ENABLED"
echo " https://${FQDN}"
echo " https://${WWW_DOMAIN}"
echo " HTTP redirects to HTTPS."
echo "============================================================"

# ------------------------------------------------------------
# 7. Automatic renewal loop
#    Check every 12 hours.
# ------------------------------------------------------------

while true; do
    sleep 12h &
    wait $! || true

    if ! kill -0 "${APACHE_PID}" 2>/dev/null; then
        echo "ERROR: Apache has exited."
        exit 1
    fi

    echo "Checking Let's Encrypt certificate renewal..."

    if certbot renew --quiet; then
        if apache2ctl configtest; then
            apache2ctl graceful
            echo "Certificate renewal check completed."
        else
            echo "WARNING: Apache configuration test failed."
        fi
    else
        echo "WARNING: Certbot renewal failed; will retry."
    fi
done
