#!/usr/bin/env bash
# AzimutCP Roundcube setup — runs once on a fresh Ubuntu server.
# Replaces the old SOGo stack. Expects azimut-panel + Dovecot + Postfix already installed.
set -euo pipefail

# 1. Install Roundcube + plugins
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  roundcube roundcube-pgsql roundcube-core \
  roundcube-plugins roundcube-plugin-contextmenu \
  dovecot-pgsql

# 2. Drop AzimutCP overrides (TLS, sieve, branding)
install -m 640 -o root -g www-data azimutcp.inc.php /etc/roundcube/azimutcp.inc.php
grep -q "azimutcp.inc.php" /etc/roundcube/config.inc.php || \
  echo 'if (file_exists(__DIR__ . "/azimutcp.inc.php")) include __DIR__ . "/azimutcp.inc.php";' >> /etc/roundcube/config.inc.php

# 3. SSO bridge needs Valkey password (www-data readable)
VALKEY_PASS=$(grep '^VALKEY_URL=' /etc/azimutcp/env | sed -n 's|.*://:\([^@]*\)@.*|\1|p')
echo "$VALKEY_PASS" > /etc/azimutcp/webmail-valkey-pass
chmod 640 /etc/azimutcp/webmail-valkey-pass
chown root:www-data /etc/azimutcp/webmail-valkey-pass

install -d -m 755 /var/www/webmail
install -m 640 -o www-data -g www-data sso.php /var/www/webmail/sso.php

# 4. Wire Dovecot SQL passdb against azimutcp.email_accounts
install -m 640 -o root -g dovecot dovecot-sql.conf.ext /etc/dovecot/
sed -i 's|^!include auth-passwdfile.conf.ext|#!include auth-passwdfile.conf.ext\n!include auth-sql.conf.ext|' /etc/dovecot/conf.d/10-auth.conf

# 5. Symlink standard plugins into the runtime dir Roundcube expects
for p in archive zipdownload managesieve; do
  ln -sf /usr/share/roundcube/plugins/$p /var/lib/roundcube/plugins/$p 2>/dev/null || true
done

# 6. Reload + nginx
install -m 644 nginx-azimutcp.conf /etc/nginx/sites-enabled/azimutcp
nginx -t && systemctl reload nginx
systemctl reload dovecot
systemctl reload php8.3-fpm
echo "Roundcube setup complete."
