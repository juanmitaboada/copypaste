#!/usr/bin/env bash
# Routing tests for deploy/nginx/*.conf with a FastCGI echo stub instead of
# php-fpm. Needs root (binds :80/:443), nginx, openssl, htpasswd, python3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(dirname "$HERE")"
T="$(mktemp -d)"
DOMAIN=cp.test
ROOT="$T/cp"
PASS=0
FAIL=0
NGV="$(nginx -v 2>&1 | sed 's|.*/||')"

mkdir -p "$T/conf/snippets" "$T/logs"
cp /etc/nginx/fastcgi_params /etc/nginx/mime.types "$T/conf/"

# instance <name> <domain> <password>: renders one cp instance exactly as the README
# does, plus test-only substitutions (self-signed cert, log dir, no IPv6).
STUBS=()
instance() {
    local name="$1" domain="$2" pw="$3" root="$T/$1" socket="$T/$1.sock"
    mkdir -p "$root/etc" "$root/app"
    cp -r "$SRC/app/public" "$root/app/"
    htpasswd -bcB "$root/etc/htpasswd" admin "$pw" 2>/dev/null
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$domain" \
        -keyout "$T/$name.key" -out "$T/$name.crt" 2>/dev/null
    local r=(sed -e "s|@NAME@|${name}|g" -e "s|@DOMAIN@|${domain}|g" -e "s|@ROOT@|${root}|g" -e "s|@SOCKET@|${socket}|g")
    "${r[@]}" "$SRC/deploy/nginx/cp-fastcgi.conf" > "$T/conf/snippets/${name}-fastcgi.conf"
    "${r[@]}" "$SRC/deploy/nginx/cp.conf" \
        | sed -e "s|/etc/letsencrypt/live/${domain}/fullchain.pem|$T/$name.crt|" \
              -e "s|/etc/letsencrypt/live/${domain}/privkey.pem|$T/$name.key|" \
              -e "s|/var/log/nginx/|$T/logs/|" \
              -e "/listen \[::\]/d" > "$T/conf/site-${name}.conf"  # sandbox has no IPv6
    if [[ "$(printf '%s\n1.25.1\n' "$NGV" | sort -V | head -1)" != "1.25.1" ]]; then
        # 'http2 on' needs nginx >= 1.25.1 (Debian 13 ships 1.26); older test nginx lacks it.
        sed -i 's|^\s*http2 on;|    # http2 on; (removed for nginx '"$NGV"')|' "$T/conf/site-${name}.conf"
    fi
    python3 "$HERE/fcgi_echo.py" "$socket" & STUBS+=($!)
}
# Two instances loaded together: every nginx-global name must be per instance.
instance cp cp.test testpw
instance cp2 cp2.test otherpw

cat > "$T/conf/nginx.conf" <<EOF
daemon off;
master_process off;
pid $T/nginx.pid;
error_log $T/logs/error.log warn;
events { worker_connections 64; }
http {
    include mime.types;
    access_log off;
    # Test only: take the client address from X-Real-IP to simulate IPv6 clients.
    set_real_ip_from 127.0.0.1;
    real_ip_header X-Real-IP;
    include site-*.conf;
}
EOF

sleep 0.3
nginx -p "$T" -c "$T/conf/nginx.conf" -t 2>&1 | sed 's/^/nginx -t: /'
nginx -p "$T" -c "$T/conf/nginx.conf" & NGINX=$!
trap 'kill $NGINX "${STUBS[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$T"' EXIT
sleep 0.7

C=(curl -s -k --noproxy "*" --resolve "$DOMAIN:443:127.0.0.1" --resolve "$DOMAIN:80:127.0.0.1" --resolve "cp2.test:443:127.0.0.1")
U="https://$DOMAIN"
AUTH=(-u admin:testpw)
check() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"
    else FAIL=$((FAIL + 1)); printf 'FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; fi
}
code() { "${C[@]}" -o /dev/null -w '%{http_code}' "$@"; }
route() { "${C[@]}" "$@" | tr '\n' ' ' | sed 's/ $//'; }
FRONT="SCRIPT_FILENAME=$ROOT/app/src/front.php"

echo "--- routes reaching PHP"
check "home" "CP_ROUTE=home CP_ZONE= CP_CODE= $FRONT REMOTE_USER= HTTPS=on SERVER_NAME=$DOMAIN" "$(route "$U/")"
check "go" "CP_ROUTE=go" "$(route "$U/go?c=x" | cut -d' ' -f1)"
check "public note" "CP_ROUTE=note CP_ZONE=public CP_CODE=abc-12_3 $FRONT REMOTE_USER=" "$(route "$U/abc-12_3" | cut -d' ' -f1-5)"
check "private needs auth" 401 "$(code "$U/private/abc123")"
check "private wrong password" 401 "$(code -u admin:bad "$U/private/abc123")"
check "private with auth" "CP_ROUTE=note CP_ZONE=private CP_CODE=abc123 $FRONT REMOTE_USER=admin" "$(route "${AUTH[@]}" "$U/private/abc123" | cut -d' ' -f1-5)"
check "/new needs auth" 401 "$(code "$U/new")"
check "/new with auth" "CP_ROUTE=new" "$(route "${AUTH[@]}" "$U/new" | cut -d' ' -f1)"
check "admin public needs auth" 401 "$(code "$U/new/abc123")"
check "admin public" "CP_ROUTE=admin CP_ZONE=public CP_CODE=abc123" "$(route "${AUTH[@]}" "$U/new/abc123" | cut -d' ' -f1-3)"
check "admin private" "CP_ROUTE=admin CP_ZONE=private CP_CODE=abc123" "$(route "${AUTH[@]}" "$U/new/private/abc123" | cut -d' ' -f1-3)"

echo "--- nothing else reaches PHP"
for p in /ABC123 /ab /abc.php /front.php /app/src/front.php /src/front.php /abc123/ /private/ /private/ab \
         /new/ /new/private/ /favicon.ico /.env /abcdefghijklmnopqrstuvwxyz0123456; do
    check "404 $p" 404 "$(code --path-as-is "$U$p")"
done
# nginx itself rejects these before any location matches.
for p in /static/../../src/front.php /abc123%00 /%2e%2e/etc/passwd; do
    check "400 $p" 400 "$(code --path-as-is "$U$p")"
done
check "static js" "200 application/javascript" "$("${C[@]}" -o /dev/null -w '%{http_code} %{content_type}' "$U/static/app.js")"
check "static missing" 404 "$(code "$U/static/nope.js")"
check "query string cannot pick script" "CP_ROUTE=note CP_ZONE=public CP_CODE=abc123 $FRONT" "$(route "$U/abc123?SCRIPT_FILENAME=/etc/passwd&CP_ZONE=private" | cut -d' ' -f1-4)"

echo "--- headers"
for p in / /static/app.js /nope.php; do
    H="$("${C[@]}" -D - -o /dev/null "$U$p" | tr -d '\r')"
    check "CSP on $p" 1 "$(rg -c "^content-security-policy: default-src 'none'; script-src 'self'" -i <<< "$H")"
    check "nosniff on $p" 1 "$(rg -ci '^x-content-type-options: nosniff' <<< "$H")"
    check "referrer on $p" 1 "$(rg -ci '^referrer-policy: same-origin' <<< "$H")"
    check "no nginx version on $p" 1 "$(rg -ci '^server: nginx$' <<< "$H")"
done

echo "--- http, size, rate limits"
check "http -> https" "301 https://$DOMAIN/abc123" "$("${C[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "http://$DOMAIN/abc123")"
head -c 420000 /dev/zero > "$T/big"
check "body over 400k -> 413" 413 "$(code -X POST --data-binary @"$T/big" "$U/abc123?a=save")"
head -c 300000 /dev/zero > "$T/ok"
check "body 300k passes nginx" 200 "$(code -X POST --data-binary @"$T/ok" "$U/abc123?a=save")"
sleep 1
N429=0; for _ in $(seq 1 10); do [[ "$(code -X POST "$U/abc123?a=save")" == 429 ]] && N429=$((N429 + 1)); done
check "10 quick saves not limited" 0 "$N429"
sleep 1
UNL=""; for _ in $(seq 1 6); do UNL+="$(code -X POST -d password=x "$U/zzz999?a=unlock") "; done
check "unlock limited after burst" "200 200 200 200 429 429" "$(xargs <<< "$UNL")"
check "saves unaffected by unlock limit" 200 "$(code -X POST "$U/zzz999?a=save")"

echo "--- access log skips live-update polls"
code "$U/logme1" >/dev/null; code "$U/logme1?a=poll" >/dev/null; code "$U/logme1?a=pollx" >/dev/null
sleep 0.2
check "normal request logged" 1 "$(rg -c 'GET /logme1 HTTP' "$T/logs/cp.access.log" || echo 0)"
check "poll not logged" 0 "$(rg -c 'GET /logme1\?a=poll HTTP' "$T/logs/cp.access.log" || echo 0)"
check "only exact a=poll is skipped" 1 "$(rg -c 'GET /logme1\?a=pollx HTTP' "$T/logs/cp.access.log" || echo 0)"
code -X POST "$U/logme2?a=poll&a=save" >/dev/null; code "$U/new?a=poll" >/dev/null; code "$U/logme3?a=poll&x=1" >/dev/null
sleep 0.2
check "POST disguised as poll is logged" 1 "$(rg -c 'POST /logme2\?a=poll&a=save HTTP' "$T/logs/cp.access.log" || echo 0)"
check "poll on another route (/new) is logged" 1 "$(rg -c 'GET /new\?a=poll HTTP' "$T/logs/cp.access.log" || echo 0)"
check "poll with extra args is logged" 1 "$(rg -c 'GET /logme3\?a=poll&x=1 HTTP' "$T/logs/cp.access.log" || echo 0)"
code "$U/private/logme4?a=poll" >/dev/null   # 401: failed auth must stay visible
sleep 0.2
check "failed-auth poll on /private is logged" 1 "$(rg -c 'GET /private/logme4\?a=poll HTTP/[0-9.]+" 401' "$T/logs/cp.access.log" || echo 0)"

echo "--- IPv6 clients are limited per /64"
sleep 1
V6=""; for h in 1 2 3 4 5; do V6+="$(code -H "X-Real-IP: 2001:db8:aa:bb::$h" -X POST -d password=x "$U/v6note?a=unlock") "; done
check "hosts of one /64 share the unlock budget" "200 200 200 200 429" "$(xargs <<< "$V6")"
check "another /64 has its own budget" 200 "$(code -H 'X-Real-IP: 2001:db8:aa:cc::1' -X POST -d password=x "$U/v6note?a=unlock")"
check "IPv4 clients keep a per-address budget" 200 "$(code -H 'X-Real-IP: 198.51.100.7' -X POST -d password=x "$U/v6note?a=unlock")"

echo "--- second instance is independent"
U2="https://cp2.test"
check "cp2 runs its own front.php" "SCRIPT_FILENAME=$T/cp2/app/src/front.php SERVER_NAME=cp2.test" \
    "$("${C[@]}" "$U2/abc123" | rg '^(SCRIPT_FILENAME|SERVER_NAME)=' | tr '\n' ' ' | sed 's/ $//')"
check "cp password rejected on cp2" 401 "$(code "${AUTH[@]}" "$U2/new")"
check "cp2 password on cp2" 200 "$(code -u admin:otherpw "$U2/new")"
check "cp2 password rejected on cp" 401 "$(code -u admin:otherpw "$U/new")"
UNL2=""; for _ in 1 2 3 4; do UNL2+="$(code -X POST -d password=x "$U2/zzz999?a=unlock") "; done
check "cp2 unlock budget untouched by cp" "200 200 200 200" "$(xargs <<< "$UNL2")"
check "per-instance logs" "cp.access.log cp.error.log cp2.access.log cp2.error.log" "$(ls "$T/logs" | rg '^cp' | xargs)"

echo
echo "passed: $PASS  failed: $FAIL"
rg -v 'limiting requests|delaying request' "$T/logs/error.log" "$T/logs/cp.error.log" "$T/logs/cp2.error.log" 2>/dev/null | rg -v '^\s*$' | head -20
exit $((FAIL > 0))
