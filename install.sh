#!/usr/bin/env bash
# Install or update cp. Idempotent: re-running updates code and config but never
# touches notes, the secret or the htpasswd file.
#
# Usage: sudo ./install.sh <domain>
# Env overrides: CP_NAME (cp; unique per instance), CP_ROOT (/srv/<name>), CP_SIZE (16M), CP_INODES (4096),
#                CP_USER / CP_GROUP (cp; unix identity of PHP), CP_WEBGROUP (www-data),
#                CP_HTUSER (first htpasswd user, defaults to $SUDO_USER),
#                CP_THEME (terminal; one name or "light dark", only used if etc/theme is missing)
set -euo pipefail

DOMAIN="${1:-}"
NAME="${CP_NAME:-cp}"
ROOT="${CP_ROOT:-/srv/${NAME}}"
SIZE="${CP_SIZE:-16M}"
INODES="${CP_INODES:-4096}"
RUNUSER="${CP_USER:-cp}"
RUNGROUP="${CP_GROUP:-cp}"
HTUSER="${CP_HTUSER:-${SUDO_USER:-admin}}"
WEBGROUP="${CP_WEBGROUP:-www-data}"
THEME="${CP_THEME:-terminal}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "install: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "run as root"
[[ -n "$DOMAIN" ]] || die "usage: $0 <domain>"
[[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || die "invalid domain: $DOMAIN"
# Used in an nginx variable name and as a unix user: no hyphens.
[[ "$NAME" =~ ^[a-z][a-z0-9_]{0,30}$ ]] || die "CP_NAME must match [a-z][a-z0-9_]*"
for id in "$RUNUSER" "$RUNGROUP"; do
    [[ "$id" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user/group name: $id"
done
# ROOT is later used with rm -rf on a subdirectory: refuse anything odd.
[[ "$ROOT" =~ ^/[A-Za-z0-9._/-]+$ && "$ROOT" != "/" ]] || die "CP_ROOT must be an absolute path"

for bin in php nginx htpasswd mkfs.ext4 systemctl mountpoint getent; do
    command -v "$bin" >/dev/null || die "missing command: $bin"
done
PHPV="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
FPM="php-fpm${PHPV}"
POOL_DIR="/etc/php/${PHPV}/fpm/pool.d"
command -v "$FPM" >/dev/null || die "missing $FPM (package php${PHPV}-fpm)"
[[ -d "$POOL_DIR" ]] || die "missing $POOL_DIR"
getent group "$WEBGROUP" >/dev/null || die "group $WEBGROUP does not exist (set CP_WEBGROUP)"
# If PHP ran in the nginx group, nginx could read etc/secret.
[[ "$RUNGROUP" != "$WEBGROUP" ]] || die "CP_GROUP must differ from CP_WEBGROUP"
SOCKET="/run/php/${NAME}.sock"
for t in $THEME; do
    [[ "$t" =~ ^[a-z0-9-]{1,32}$ && -f "${SRC}/app/public/static/themes/${t}.css" ]] \
        || die "unknown theme '$t' (see app/public/static/themes/)"
done

render() {
    sed -e "s|@NAME@|${NAME}|g" -e "s|@USER@|${RUNUSER}|g" -e "s|@GROUP@|${RUNGROUP}|g" \
        -e "s|@DOMAIN@|${DOMAIN}|g" -e "s|@ROOT@|${ROOT}|g" \
        -e "s|@SOCKET@|${SOCKET}|g" -e "s|@WEBGROUP@|${WEBGROUP}|g" "$1"
}

step "system user ${RUNUSER}:${RUNGROUP}"
getent group "$RUNGROUP" >/dev/null || groupadd --system "$RUNGROUP"
if ! id "$RUNUSER" >/dev/null 2>&1; then
    useradd --system --gid "$RUNGROUP" --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "$RUNUSER"
fi

step "application code -> ${ROOT}/app"
install -d -o root -g root -m 0755 "$ROOT"
rm -rf "${ROOT}/app.new"
cp -r "${SRC}/app" "${ROOT}/app.new"
chown -R root:root "${ROOT}/app.new"
find "${ROOT}/app.new" -type d -exec chmod 0755 {} +
find "${ROOT}/app.new" -type f -exec chmod 0644 {} +
rm -rf "${ROOT}/app.old"
if [[ -d "${ROOT}/app" ]]; then mv "${ROOT}/app" "${ROOT}/app.old"; fi
mv "${ROOT}/app.new" "${ROOT}/app"
rm -rf "${ROOT}/app.old"

step "secrets in ${ROOT}/etc"
install -d -o root -g "$RUNGROUP" -m 0750 "${ROOT}/etc"
if [[ ! -s "${ROOT}/etc/secret" ]]; then
    (umask 027; head -c 48 /dev/urandom | base64 -w0 > "${ROOT}/etc/secret")
fi
chown root:"$RUNGROUP" "${ROOT}/etc/secret"
chmod 0640 "${ROOT}/etc/secret"
if [[ ! -s "${ROOT}/etc/htpasswd" ]]; then
    echo "Password for HTTP user '${HTUSER}' (protects /new and /private):"
    htpasswd -B -c "${ROOT}/etc/htpasswd" "$HTUSER"
fi
# nginx reads it; the instance user (PHP) never needs it.
chown root:"$WEBGROUP" "${ROOT}/etc/htpasswd"
chmod 0640 "${ROOT}/etc/htpasswd"
# nginx must traverse etc/ to reach htpasswd, but must not read the secret.
chmod 0751 "${ROOT}/etc"
if [[ ! -s "${ROOT}/etc/theme" ]]; then
    echo "$THEME" > "${ROOT}/etc/theme"
fi
# Not secret, but only root may change it.
chown root:root "${ROOT}/etc/theme"
chmod 0644 "${ROOT}/etc/theme"

step "size-capped data filesystem (${SIZE}, ${INODES} inodes)"
IMG="${ROOT}/data.img"
if [[ ! -f "$IMG" ]]; then
    truncate -s "$SIZE" "$IMG"
    chmod 0600 "$IMG"
    mkfs.ext4 -q -N "$INODES" -m 0 -L cpdata "$IMG"
fi
install -d -m 0755 "${ROOT}/data"
FSTAB_LINE="${IMG} ${ROOT}/data ext4 loop,nodev,nosuid,noexec,noatime 0 2"
if ! awk -v m="${ROOT}/data" '$2 == m { found = 1 } END { exit !found }' /etc/fstab; then
    echo "$FSTAB_LINE" >> /etc/fstab
    systemctl daemon-reload
fi
mountpoint -q "${ROOT}/data" || mount "${ROOT}/data"
chown "$RUNUSER:$RUNGROUP" "${ROOT}/data"
chmod 0700 "${ROOT}/data"
for zone in public private; do
    install -d -o "$RUNUSER" -g "$RUNGROUP" -m 0700 "${ROOT}/data/${zone}"
done

step "php-fpm pool ${POOL_DIR}/${NAME}.conf"
render "${SRC}/deploy/php-fpm/cp.conf" > "${POOL_DIR}/${NAME}.conf"
"$FPM" -t
systemctl reload "php${PHPV}-fpm"

step "nginx site"
render "${SRC}/deploy/nginx/cp-fastcgi.conf" > "/etc/nginx/snippets/${NAME}-fastcgi.conf"
render "${SRC}/deploy/nginx/cp.conf" > "/etc/nginx/sites-available/${DOMAIN}.conf"
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    LINK="/etc/nginx/sites-enabled/${DOMAIN}.conf"
    NEWLINK=0; [[ -e "$LINK" ]] || NEWLINK=1
    ln -sfn "/etc/nginx/sites-available/${DOMAIN}.conf" "$LINK"
    if ! nginx -t; then
        # Never leave a broken site enabled: every later nginx reload would fail too.
        [[ $NEWLINK -eq 1 ]] && rm -f "$LINK"
        die "nginx -t failed; site $( [[ $NEWLINK -eq 1 ]] && echo 'disabled again' || echo 'left as it was enabled before, fix it' )"
    fi
    systemctl reload nginx
else
    echo "WARNING: no certificate at /etc/letsencrypt/live/${DOMAIN}/; site written but NOT enabled." >&2
    echo "         Get one (see README), then re-run this script." >&2
fi

step "purge timer"
render "${SRC}/deploy/systemd/cp-purge.service" > "/etc/systemd/system/${NAME}-purge.service"
render "${SRC}/deploy/systemd/cp-purge.timer" > "/etc/systemd/system/${NAME}-purge.timer"
systemctl daemon-reload
systemctl enable --now "${NAME}-purge.timer"

step "done: https://${DOMAIN}/"
