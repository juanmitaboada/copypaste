#!/usr/bin/env bash
# Read-only security audit of one installed cp instance. Changes nothing.
#
# Usage (as root, same variables as README step 0):
#   CP_NAME=cp CP_ROOT=/var/www/cp CP_DOMAIN=cp.example.org tools/audit.sh
# Optional: CP_USER, CP_GROUP (default cp), CP_WEBGROUP (www-data), PHPV (8.4),
#           CP_SKIP_HTTP=1 to skip the checks made over HTTPS.
# Exit status: 0 if no FAIL (WARNs are allowed), 1 otherwise.
set -uo pipefail

NAME="${CP_NAME:?set CP_NAME}"
ROOT="${CP_ROOT:?set CP_ROOT}"
DOMAIN="${CP_DOMAIN:?set CP_DOMAIN}"
RUSER="${CP_USER:-cp}"
RGROUP="${CP_GROUP:-cp}"
WEBGROUP="${CP_WEBGROUP:-www-data}"
PHPV="${PHPV:-8.4}"
POOL="/etc/php/${PHPV}/fpm/pool.d/${NAME}.conf"
FAILS=0
WARNS=0

pass() { printf 'PASS  %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; WARNS=$((WARNS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
# expect <description> <condition...>: PASS if the command succeeds, FAIL otherwise.
expect() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
mode_owner() { stat -c '%a %U:%G' "$1" 2>/dev/null; }
section() { printf '\n== %s\n' "$1"; }

[[ $EUID -eq 0 ]] || { echo "audit: run as root (it reads protected files)" >&2; exit 2; }
[[ "$NAME" =~ ^[a-z][a-z0-9_]*$ ]] || { echo "audit: invalid CP_NAME" >&2; exit 2; }

section "files and permissions"
[[ "$(mode_owner "$ROOT")" == "755 root:root" ]] && pass "$ROOT is 755 root:root" || fail "$ROOT should be 755 root:root (is $(mode_owner "$ROOT"))"
if [[ -z "$(find "$ROOT/app" \( ! -user root -o -perm /022 \) -print -quit 2>/dev/null)" ]]; then
    pass "app/ is owned by root and not group/world-writable"
else
    fail "app/ has files not owned by root or writable by others: $(find "$ROOT/app" \( ! -user root -o -perm /022 \) -print | head -3 | xargs)"
fi
expect "PHP user $RUSER cannot write app/" bash -c "! runuser -u '$RUSER' -- test -w '$ROOT/app/src/front.php'"
[[ "$(mode_owner "$ROOT/etc")" == "751 root:$RGROUP" ]] && pass "etc/ is 751 root:$RGROUP" || fail "etc/ should be 751 root:$RGROUP (is $(mode_owner "$ROOT/etc"))"
[[ "$(mode_owner "$ROOT/etc/secret")" == "640 root:$RGROUP" ]] && pass "etc/secret is 640 root:$RGROUP" || fail "etc/secret should be 640 root:$RGROUP (is $(mode_owner "$ROOT/etc/secret"))"
secret_len="$(tr -d '[:space:]' < "$ROOT/etc/secret" 2>/dev/null | wc -c)"
(( secret_len >= 32 )) && pass "etc/secret has $secret_len characters" || fail "etc/secret is missing or shorter than 32 characters"
expect "nginx group $WEBGROUP cannot read etc/secret" bash -c "! runuser -u nobody -g '$WEBGROUP' -- cat '$ROOT/etc/secret'"
[[ "$(mode_owner "$ROOT/etc/htpasswd")" == "640 root:$WEBGROUP" ]] && pass "etc/htpasswd is 640 root:$WEBGROUP" || fail "etc/htpasswd should be 640 root:$WEBGROUP (is $(mode_owner "$ROOT/etc/htpasswd"))"
if [[ -s "$ROOT/etc/htpasswd" ]] && ! rg -qv '^[^:]+:\$2[aby]\$' "$ROOT/etc/htpasswd"; then
    pass "every htpasswd entry uses bcrypt"
else
    fail "htpasswd is empty or has non-bcrypt entries (recreate them with htpasswd -B)"
fi
expect "PHP user $RUSER cannot read etc/htpasswd" bash -c "! runuser -u '$RUSER' -- cat '$ROOT/etc/htpasswd'"
if [[ -e "$ROOT/etc/theme" ]]; then
    [[ "$(stat -c '%U' "$ROOT/etc/theme")" == root ]] && [[ ! "$(stat -c '%a' "$ROOT/etc/theme")" =~ [2367].$|[2367]$ ]] \
        && pass "etc/theme is owned by root and not writable by others" || fail "etc/theme must be owned by root and writable only by root"
fi

section "data filesystem"
opts="$(findmnt -n -o OPTIONS --target "$ROOT/data" 2>/dev/null)"
if [[ "$(findmnt -n -o TARGET --target "$ROOT/data" 2>/dev/null)" == "$ROOT/data" ]]; then
    pass "data/ is a separate mount ($(findmnt -n -o SOURCE,SIZE --target "$ROOT/data" | xargs))"
    for o in nodev nosuid noexec; do [[ ",$opts," == *",$o,"* ]] && pass "data/ mounted $o" || fail "data/ must be mounted $o"; done
else
    fail "data/ is not a separate mount: nothing caps the space notes can use"
fi
[[ "$(mode_owner "$ROOT/data")" == "700 $RUSER:$RGROUP" ]] && pass "data/ is 700 $RUSER:$RGROUP" || fail "data/ should be 700 $RUSER:$RGROUP (is $(mode_owner "$ROOT/data"))"
[[ -z "$(find "$ROOT/data" -mindepth 1 -maxdepth 1 ! -name public ! -name private ! -name lost+found -print -quit)" ]] \
    && pass "data/ holds only public/ and private/" || warn "unexpected entries in data/: $(find "$ROOT/data" -mindepth 1 -maxdepth 1 ! -name public ! -name private ! -name lost+found | head -3 | xargs)"
stray="$(find "$ROOT/data/public" "$ROOT/data/private" -type f ! -name '*.txt' ! -name '*.json' ! -name '*.tmp' -print 2>/dev/null | head -3)"
[[ -z "$stray" ]] && pass "no unexpected files among the notes" || warn "unexpected files among the notes: $stray"
[[ -f "$ROOT/data.img" && "$(stat -c '%a' "$ROOT/data.img")" == 600 ]] && pass "data.img is 600" || warn "data.img missing or not 600"
use="$(df --output=pcent "$ROOT/data" 2>/dev/null | tail -1 | tr -dc 0-9)"; iuse="$(df --output=ipcent "$ROOT/data" 2>/dev/null | tail -1 | tr -dc 0-9)"
(( ${use:-0} < 90 && ${iuse:-0} < 90 )) && pass "data/ usage ${use}% space, ${iuse}% inodes" || warn "data/ nearly full: ${use}% space, ${iuse}% inodes"

section "php-fpm pool ($POOL)"
if [[ -f "$POOL" ]]; then
    pv() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$POOL" | tail -1; }
    [[ "$(pv 'user')" == "$RUSER" && "$(pv 'group')" == "$RGROUP" ]] && pass "pool runs as $RUSER:$RGROUP" || fail "pool user/group are $(pv user):$(pv group), expected $RUSER:$RGROUP"
    [[ "$RGROUP" != "$WEBGROUP" ]] && pass "pool group differs from the nginx group" || fail "pool group is the nginx group: nginx could read etc/secret"
    [[ "$(pv 'php_admin_value\[open_basedir\]')" == "$ROOT/app/:$ROOT/data/:$ROOT/etc/secret:$ROOT/etc/theme" ]] \
        && pass "open_basedir limited to app/, data/, etc/secret, etc/theme" || fail "open_basedir is '$(pv 'php_admin_value\[open_basedir\]')'"
    df_list="$(pv 'php_admin_value\[disable_functions\]')"
    missing=""; for f in exec passthru shell_exec system proc_open popen; do [[ ",$df_list," == *",$f,"* ]] || missing+=" $f"; done
    [[ -z "$missing" ]] && pass "process functions disabled" || fail "disable_functions lacks:$missing"
    for f in allow_url_fopen allow_url_include file_uploads display_errors expose_php; do
        [[ "$(pv "php_admin_flag\[$f\]")" == off ]] && pass "$f = off" || fail "$f should be php_admin_flag off"
    done
    [[ "$(pv 'listen.mode')" == 0660 && "$(pv 'listen.group')" == "$WEBGROUP" ]] && pass "socket 0660, group $WEBGROUP" || fail "socket should be listen.mode 0660, listen.group $WEBGROUP"
    [[ "$(pv 'clear_env')" == yes ]] && pass "clear_env = yes" || warn "clear_env is not yes"
else
    fail "pool file not found"
fi
others="$(rg -l "^[[:space:]]*(user|group)[[:space:]]*=[[:space:]]*${WEBGROUP}[[:space:]]*$" "/etc/php/${PHPV}/fpm/pool.d/" 2>/dev/null | xargs)"
if [[ -z "$others" ]]; then
    pass "no PHP pool runs as $WEBGROUP"
else
    warn "PHP pools running as $WEBGROUP ($others): code there can read htpasswd and talk to cp's socket (see SECURITY.md)"
fi
if command -v "php-fpm${PHPV}" >/dev/null; then
    "php-fpm${PHPV}" -t >/dev/null 2>&1 && pass "php-fpm${PHPV} -t" || fail "php-fpm${PHPV} -t reports errors"
fi

section "nginx"
if conf="$(nginx -T 2>/dev/null)"; then
    n="$(rg -c "limit_req_zone .* zone=${NAME}_req:" <<< "$conf" || true)"
    [[ "$n" == 1 ]] && pass "site loaded exactly once" || fail "zone ${NAME}_req defined $n times (site missing or included twice)"
    rg -q "server_tokens off" <<< "$conf" && pass "server_tokens off" || warn "server_tokens off not found"
    rg -q "fastcgi_param SCRIPT_FILENAME $ROOT/app/src/front.php;" <<< "$conf" && pass "fixed SCRIPT_FILENAME" || fail "SCRIPT_FILENAME is not fixed to $ROOT/app/src/front.php"
    rg -q "fastcgi_pass unix:/run/php/${NAME}.sock;" <<< "$conf" && pass "passes to /run/php/${NAME}.sock" || fail "fastcgi_pass is not /run/php/${NAME}.sock"
    if rg -q 'location ~ \\\.php\$|location ~ \.php' <<< "$(sed -n "/server_name ${DOMAIN//./\\.};/,/^}/p" <<< "$conf")"; then
        fail "a generic .php location exists in the $DOMAIN server block"
    else
        pass "no generic .php location in the $DOMAIN server block"
    fi
else
    fail "nginx -T failed: $(nginx -t 2>&1 | rg -m1 'emerg|error' | sed 's/^.*\] //')"
fi
cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
if [[ -f "$cert" ]]; then
    openssl x509 -checkend $((14 * 86400)) -noout -in "$cert" >/dev/null && pass "certificate valid for 14+ days" || warn "certificate expires within 14 days"
else
    warn "no certificate at $cert (checked the default letsencrypt path only)"
fi

section "purge timer"
if systemctl is-system-running >/dev/null 2>&1 || [[ "$(systemctl is-system-running 2>/dev/null)" == degraded ]]; then
    systemctl is-enabled --quiet "${NAME}-purge.timer" && pass "${NAME}-purge.timer enabled" || fail "${NAME}-purge.timer not enabled"
    systemctl is-active --quiet "${NAME}-purge.timer" && pass "${NAME}-purge.timer active" || fail "${NAME}-purge.timer not active"
    res="$(systemctl show -p Result --value "${NAME}-purge.service" 2>/dev/null)"
    [[ "$res" == success ]] && pass "last purge run succeeded" || warn "last purge result: ${res:-unknown}"
else
    warn "systemd not reachable: purge timer not checked"
fi

if [[ "${CP_SKIP_HTTP:-0}" != 1 ]]; then
    section "HTTP (https://$DOMAIN)"
    U="https://$DOMAIN"
    C=(curl -s --max-time 10)
    code() { "${C[@]}" -o /dev/null -w '%{http_code}' "$@"; }
    h="$("${C[@]}" -D - -o /dev/null "$U/" | tr -d '\r')"
    if [[ -z "$h" ]]; then
        fail "cannot reach $U/"
    else
        rg -qi "^content-security-policy: default-src 'none'; script-src 'self'" <<< "$h" && pass "CSP" || fail "CSP header missing or changed"
        rg -qi '^x-content-type-options: nosniff' <<< "$h" && pass "nosniff" || fail "X-Content-Type-Options missing"
        rg -qi '^referrer-policy: same-origin' <<< "$h" && pass "Referrer-Policy same-origin" || fail "Referrer-Policy is not same-origin"
        rg -qi '^strict-transport-security:' <<< "$h" && pass "HSTS" || warn "HSTS header missing"
        rg -qi '^server: nginx$' <<< "$h" && pass "Server header hides the version" || warn "Server header shows a version"
        [[ "$(code "http://$DOMAIN/abc123")" == 301 ]] && pass "http redirects to https" || fail "http does not redirect to https"
        [[ "$(code "$U/new")" == 401 ]] && pass "/new asks for credentials" || fail "/new is not behind basic auth"
        [[ "$(code "$U/private/abc123")" == 401 ]] && pass "/private/ asks for credentials" || fail "/private/ is not behind basic auth"
        for p in /front.php /app/src/front.php /index.php /data/public/ /etc/secret /.env; do
            c="$(code --path-as-is "$U$p")"; [[ "$c" == 404 || "$c" == 400 ]] && pass "$p -> $c" || fail "$p -> $c (expected 404)"
        done
        home="$("${C[@]}" "$U/")"
        rg -qi 'note|paste' <<< "$home" && warn "entry page mentions notes or pasting" || pass "entry page gives nothing away"
    fi
fi

printf '\n%d FAIL, %d WARN\n' "$FAILS" "$WARNS"
exit $((FAILS > 0))
