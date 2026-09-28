#!/usr/bin/env bash
# Functional tests for the PHP app through tests/router.php (php -S).
# Usage: tests/app_test.sh   (needs php, curl)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
PORT=8099
BASE="http://127.0.0.1:${PORT}"
UA="Mozilla/5.0 test"
PASS=0
FAIL=0

mkdir -p "$WORK/data/public" "$WORK/data/private"
head -c 48 /dev/urandom | base64 -w0 > "$WORK/secret"
# Several workers so the concurrent-reveal test really races.
PHP_CLI_SERVER_WORKERS=4 CP_DATA_DIR="$WORK/data" CP_SECRET_FILE="$WORK/secret" CP_THEME_FILE="$WORK/theme" \
    php -S "127.0.0.1:${PORT}" -t "$HERE/../app/public" "$HERE/router.php" >"$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$WORK"' EXIT
sleep 0.5

check() { # check <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3"
    fi
}
status() { curl -s -o /dev/null -w '%{http_code}' -A "$UA" "$@"; }
body() { curl -s -A "$UA" "$@"; }
header() { curl -s -D - -o /dev/null -A "$UA" "${@:2}" | tr -d '\r' | awk -v h="$1" 'tolower($0) ~ "^"tolower(h)":" {sub(/^[^:]*: /,""); print}'; }
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
hash_of() { body "$BASE$1" | sed -n 's/.*data-hash="\([0-9a-f]*\)".*/\1/p'; }
save() { # save <path> <base|-> <text> [extra curl args]
    local p="$1" b="$2" t="$3"; shift 3
    local hb=(); [[ "$b" != "-" ]] && hb=(-H "X-CP-Base: $b")
    curl -s -o /dev/null -w '%{http_code}' -A "$UA" -X POST "${hb[@]}" \
        -H 'Content-Type: text/plain' --data-binary "$t" "$@" "$BASE$p?a=save"
}
create() { # create key=value ... -> prints Location
    local args=()
    for kv in "$@"; do args+=(--data-urlencode "$kv"); done
    header Location "$BASE/new" -X POST "${args[@]}"
}

echo "--- home and /go"
check "home 200" 200 "$(status "$BASE/")"
check "go public" "/abc123" "$(header Location "$BASE/go?c=abc123")"
check "go priv/ prefix, case-insensitive" "/private/abc123" "$(header Location "$BASE/go?c=Priv/AbC123")"
check "go private/ prefix" "/private/abc123" "$(header Location "$BASE/go?c=private/abc123")"
check "go invalid" 400 "$(status "$BASE/go?c=../../etc")"
check "go too short" 400 "$(status "$BASE/go?c=ab")"
check "missing note 404" 404 "$(status "$BASE/xyz999")"
check "PHP rejects injected traversal code" 404 "$(status -H 'X-Test-CP-Code: ../../etc/passwd' "$BASE/xyz999")"
check "PHP rejects injected zone" 404 "$(status -H 'X-Test-CP-Zone: ../etc' "$BASE/xyz999")"
check "PUT refused" 405 "$(status -X PUT "$BASE/xyz999")"

echo "--- creation"
check "create editable -> opens the note" "/hello1" "$(create code=hello1 zone=public mode=edit expiry=idle7d content=hi)"
check "duplicate code" 409 "$(status -X POST -d code=hello1 -d zone=public -d mode=edit -d expiry=never "$BASE/new")"
check "same code other zone" 409 "$(status -X POST -d code=hello1 -d zone=private -d mode=edit -d expiry=never "$BASE/new")"
check "reserved code" 400 "$(status -X POST -d code=static -d zone=public -d mode=edit -d expiry=never "$BASE/new")"
check "invalid code" 400 "$(status -X POST -d code=Bad.Code -d zone=public -d mode=edit -d expiry=never "$BASE/new")"
check "invalid mode" 400 "$(status -X POST -d code=okcode -d zone=public -d mode=root -d expiry=never "$BASE/new")"
check "burn without content" 400 "$(status -X POST -d code=okcode -d zone=public -d mode=burn -d expiry=never "$BASE/new")"
RND="$(create zone=public mode=edit expiry=never)"
check "random code shape" 1 "$([[ "$RND" =~ ^/[abcdefghjkmnpqrstuvwxyz23456789]{7}$ ]] && echo 1 || echo 0)"
check "admin page 200" 200 "$(status "$BASE/new/hello1")"
# Only editable notes open after creation; the others stay on their settings page.
check "create readonly -> settings" "/new/stayro?created=1" "$(create code=stayro zone=public mode=readonly expiry=never content=x)"
check "create burn -> settings" "/new/stayburn?created=1" "$(create code=stayburn zone=public mode=burn expiry=never content=x)"
check "burn untouched by the redirect" 200 "$(status "$BASE/stayburn")"
PWLOC="$(curl -s -D - -o /dev/null -A "$UA" -X POST --data-urlencode code=pwjump -d zone=public -d mode=edit -d expiry=never -d password=s3 -d content=inside "$BASE/new" | tr -d '\r')"
check "create editable with password -> opens the note" "/pwjump" "$(awk 'tolower($0) ~ /^location:/ {print $2}' <<< "$PWLOC")"
PWCOOKIE="$(awk 'tolower($0) ~ /^set-cookie: cp_public_pwjump=/ {sub(/^[^:]*: /,""); sub(/;.*/,""); print}' <<< "$PWLOC")"
check "owner gets the unlock cookie (no password prompt)" "inside" "$(body -H "Cookie: $PWCOOKIE" "$BASE/pwjump?raw")"
check "others still need the password" 403 "$(status "$BASE/pwjump?raw")"
check "new form lists note" 1 "$(body "$BASE/new" | rg -c '>hello1<')"

echo "--- editor, raw, save, conflict"
check "editor 200" 200 "$(status "$BASE/hello1")"
H0="$(hash_of /hello1)"
check "hash matches content" "$(sha hi)" "$H0"
check "raw via ?raw" "hi" "$(body "$BASE/hello1?raw")"
check "raw via curl UA" "hi" "$(curl -s "$BASE/hello1")"
check "save with base" 200 "$(save /hello1 "$H0" 'second')"
check "stale base -> 409" 409 "$(save /hello1 "$H0" 'third')"
check "content unchanged after 409" "second" "$(curl -s "$BASE/hello1")"
check "curl save without base" 200 "$(save /hello1 - 'from curl')"
check "empty save keeps note" 200 "$(save /hello1 - '')"
check "note still exists" 200 "$(status "$BASE/hello1")"
check "html is escaped" 200 "$(save /hello1 - '</textarea><script>alert(1)</script>')"
check "no raw script in page" 0 "$(body "$BASE/hello1" | rg -c '<script>alert' || echo 0)"
head -c 270000 /dev/zero | tr '\0' a > "$WORK/big"
check "oversize -> 413" 413 "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @"$WORK/big" "$BASE/hello1?a=save")"
check "invalid utf-8 -> 400" 400 "$(printf '\xff\xfe' | curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$BASE/hello1?a=save")"

echo "--- CSRF guard"
check "foreign Origin refused" 403 "$(save /hello1 - 'x' -H 'Origin: https://evil.example')"
check "Sec-Fetch-Site cross-site refused" 403 "$(save /hello1 - 'x' -H 'Sec-Fetch-Site: cross-site')"
check "same Origin allowed" 200 "$(save /hello1 - 'ok' -H "Origin: $BASE" -H 'Sec-Fetch-Site: same-origin')"
# Form navigations can send "Origin: null"; the browser-set Sec-Fetch-Site decides.
check "Origin null + same-origin fetch site allowed" 200 "$(save /hello1 - 'ok' -H 'Origin: null' -H 'Sec-Fetch-Site: same-origin')"
check "Origin null without Sec-Fetch-Site refused" 403 "$(save /hello1 - 'x' -H 'Origin: null')"
check "same-site (other subdomain) refused" 403 "$(save /hello1 - 'x' -H 'Sec-Fetch-Site: same-site')"
check "cross-site wins over matching Origin" 403 "$(save /hello1 - 'x' -H "Origin: $BASE" -H 'Sec-Fetch-Site: cross-site')"
check "create form with Origin null allowed" 303 "$(status -X POST -H 'Origin: null' -H 'Sec-Fetch-Site: same-origin' -d code=nullorig -d zone=public -d mode=edit -d expiry=never "$BASE/new")"

echo "--- delete"
check "visitor delete" 200 "$(status -X POST "$BASE/hello1?a=delete")"
check "gone after delete" 404 "$(status "$BASE/hello1")"
check "files removed" 0 "$(ls "$WORK/data/public" | rg -c '^hello1\.' || echo 0)"

echo "--- password"
create code=locked zone=public mode=edit expiry=never password=s3cret content=topsecret >/dev/null
check "locked shows unlock form" 1 "$(body "$BASE/locked" | rg -c 'This note is protected')"
check "locked page hides content" 0 "$(body "$BASE/locked" | rg -c topsecret || echo 0)"
check "locked raw 403" 403 "$(status "$BASE/locked?raw")"
check "locked save 403" 403 "$(save /locked - 'pwned')"
check "wrong password 403" 403 "$(status -X POST -d password=nope "$BASE/locked?a=unlock")"
COOKIE="$(header Set-Cookie "$BASE/locked?a=unlock" -X POST -d password=s3cret | cut -d';' -f1)"
check "cookie issued" 1 "$([[ "$COOKIE" == cp_public_locked=* ]] && echo 1 || echo 0)"
check "cookie flags" 1 "$(header Set-Cookie "$BASE/locked?a=unlock" -X POST -d password=s3cret | rg -c 'path=/locked; HttpOnly; SameSite=Strict')"
check "unlocked raw" "topsecret" "$(body -H "Cookie: $COOKIE" "$BASE/locked?raw")"
check "forged cookie rejected" 403 "$(status -H 'Cookie: cp_public_locked=deadbeef' "$BASE/locked?raw")"
HL="$(body -H "Cookie: $COOKIE" "$BASE/locked" | sed -n 's/.*data-hash="\([0-9a-f]*\)".*/\1/p')"
check "unlocked save" 200 "$(save /locked "$HL" 'edited' -H "Cookie: $COOKIE")"
check "password stored hashed" 0 "$(rg -c s3cret "$WORK/data/public/locked.json" || echo 0)"
check "argon2id in use" 1 "$(rg -c 'argon2id' "$WORK/data/public/locked.json")"

echo "--- admin changes password -> old cookie invalid"
HA="$(sha edited)"
check "admin save editable -> opens the note" "/locked" "$(header Location "$BASE/new/locked?a=save" -X POST -d base="$HA" -d content=edited -d mode=edit -d expiry=never -d password_action=set -d password=other)"
check "old cookie now rejected" 403 "$(status -H "Cookie: $COOKIE" "$BASE/locked?raw")"
check "admin stale base 409" 409 "$(status -X POST -d base=0000 -d content=x -d mode=edit -d expiry=never "$BASE/new/locked?a=save")"
check "admin clear password" 303 "$(status -X POST -d base="$HA" -d content=edited -d mode=edit -d expiry=never -d password_action=clear "$BASE/new/locked?a=save")"
check "open again without password" "edited" "$(body "$BASE/locked?raw")"

echo "--- read-only"
create code=readme zone=public mode=readonly expiry=never content=fixed >/dev/null
check "readonly page has readonly textarea" 1 "$(body "$BASE/readme" | rg -c '<textarea id="content" spellcheck="false" autofocus readonly>')"
check "readonly save 403" 403 "$(save /readme - 'changed')"
check "readonly visitor delete 403" 403 "$(status -X POST "$BASE/readme?a=delete")"
check "admin save readonly -> settings" "/new/readme?saved=1" "$(header Location "$BASE/new/readme?a=save" -X POST -d base="$(sha fixed)" -d content=v2 -d mode=readonly -d expiry=never)"
check "readonly admin delete" 303 "$(status -X POST "$BASE/new/readme?a=delete")"
check "readonly gone" 404 "$(status "$BASE/readme")"

echo "--- burn after reading"
create code=burnme zone=public mode=burn expiry=never content=once >/dev/null
check "GET does not burn" 200 "$(status "$BASE/burnme")"
check "GET again still there" 1 "$(body "$BASE/burnme" | rg -c 'Show and destroy')"
check "raw GET does not burn" 409 "$(status "$BASE/burnme?raw")"
check "save refused" 403 "$(save /burnme - 'x')"
R1="$WORK/r1"; R2="$WORK/r2"
curl -s -o "$R1" -w '%{http_code}' -X POST "$BASE/burnme?a=reveal&raw" > "$R1.code" & P1=$!
curl -s -o "$R2" -w '%{http_code}' -X POST "$BASE/burnme?a=reveal&raw" > "$R2.code" & P2=$!
wait "$P1" "$P2"
CODES="$(sort <<< "$(cat "$R1.code"; echo; cat "$R2.code")" | tr '\n' ' ' | xargs)"
check "concurrent reveal: exactly one wins" "200 404" "$CODES"
check "winner got content" 1 "$(cat "$R1" "$R2" | rg -c 'once')"
check "burned note gone" 404 "$(status "$BASE/burnme")"
create code=burnhtml zone=public mode=burn expiry=never content=hello >/dev/null
check "HTML reveal page" 1 "$(body -X POST "$BASE/burnhtml?a=reveal" | rg -c 'Deleted from the server')"
# Reloading the reveal page re-POSTs the form: answer with a page, not API JSON.
check "reveal again (reload) -> 404 HTML" "404 text/html; charset=utf-8" \
    "$(curl -s -o /dev/null -A "$UA" -w '%{http_code} %{content_type}' -X POST "$BASE/burnhtml?a=reveal")"
check "reveal again shows the neutral page" 1 "$(body -X POST "$BASE/burnhtml?a=reveal" | rg -c '<h1>Nothing here</h1>')"
check "raw reveal again -> plain text 404" "404 Not found" \
    "$(curl -s -w '%{http_code}' -X POST "$BASE/burnhtml?a=reveal&raw" | tr -d '\n' | sed -E 's/^(.*)([0-9]{3})$/\2 \1/')"
check "unlock on missing note -> 404 HTML" "404 text/html; charset=utf-8" \
    "$(curl -s -o /dev/null -A "$UA" -w '%{http_code} %{content_type}' -X POST -d password=x "$BASE/nope123?a=unlock")"
check "save on missing note stays JSON" "404 application/json" \
    "$(curl -s -o /dev/null -A "$UA" -w '%{http_code} %{content_type}' -X POST --data-binary x "$BASE/nope123?a=save")"
create code=burnpw zone=public mode=burn expiry=never password=pw content=hidden >/dev/null
check "locked burn reveal -> unlock page, not JSON" "403 1" \
    "$(curl -s -A "$UA" -w ' %{http_code}' -X POST "$BASE/burnpw?a=reveal" | tr -d '\n' | sed -E 's/.*(This note is protected).* ([0-9]{3})$/\2 1/')"
check "locked burn not destroyed" 200 "$(status "$BASE/burnpw")"

echo "--- private zone"
check "create private editable -> opens the note" "/private/mine01" "$(create code=mine01 zone=private mode=edit expiry=never content=private-stuff)"
check "private via /private/" "private-stuff" "$(curl -s "$BASE/private/mine01")"
check "private not reachable as public" 404 "$(status "$BASE/mine01")"
check "private stored separately" 1 "$(ls "$WORK/data/private" | rg -c '^mine01\.txt$')"
check "private editor has settings link" 1 "$(body "$BASE/private/mine01" | rg -c 'href="/new/private/mine01"')"
check "Share button carries the canonical private path" 1 "$(body "$BASE/private/mine01" | rg -c 'data-share="/private/mine01"')"

echo "--- expiry"
create code=short1 zone=public mode=edit expiry=1h content=tmp >/dev/null
create code=idle01 zone=public mode=edit expiry=idle7d content=tmp >/dev/null
check "fresh 1h note alive" 200 "$(status "$BASE/short1")"
PURGED="$(CP_DATA_DIR="$WORK/data" php -r '
require "'"$HERE"'/../app/src/lib.php";
$s = new Cp\Store(getenv("CP_DATA_DIR"));
echo $s->purgeExpired(time() + 7200), " ", $s->purgeExpired(time() + 8 * 86400);')"
check "purge: 1h note after 2h, idle note after 8d" "1 1" "$PURGED"
check "short note gone" 404 "$(status "$BASE/short1")"
check "never-expiring private kept" 200 "$(status "$BASE/private/mine01")"
check "purge.php runs" 1 "$(CP_DATA_DIR="$WORK/data" CP_SECRET_FILE="$WORK/secret" php "$HERE/../app/bin/purge.php" | rg -c '^cp-purge: removed 0 expired note')"

echo "--- live-update poll"
poll() { # poll <path> <base|-> [extra curl args] -> status code
    local p="$1" b="$2"; shift 2
    local hb=(); [[ "$b" != "-" ]] && hb=(-H "X-CP-Base: $b")
    curl -s -o /dev/null -w '%{http_code}' -A "$UA" "${hb[@]}" "$@" "$BASE$p?a=poll"
}
create code=live01 zone=public mode=edit expiry=never content=v1 >/dev/null
check "poll unchanged -> 204" 204 "$(poll /live01 "$(sha v1)")"
check "poll with old hash -> 200" 200 "$(poll /live01 "$(sha old)")"
check "poll without base -> 200" 200 "$(poll /live01 -)"
save /live01 - 'v2' >/dev/null
check "poll returns new content and hash" "{\"hash\":\"$(sha v2)\",\"content\":\"v2\"}" \
    "$(curl -s -A "$UA" -H "X-CP-Base: $(sha v1)" "$BASE/live01?a=poll")"
check "poll after change with new hash -> 204" 204 "$(poll /live01 "$(sha v2)")"
check "poll missing note -> 404" 404 "$(poll /nope99 -)"
check "poll is GET-only (POST is an action)" 400 "$(status -X POST "$BASE/live01?a=poll")"
create code=live02 zone=public mode=readonly expiry=never content=ro >/dev/null
check "poll readonly note -> 200" 200 "$(poll /live02 -)"
create code=live03 zone=public mode=edit expiry=never password=pw content=secret >/dev/null
check "poll locked note -> 403" 403 "$(poll /live03 -)"
check "locked poll leaks no content" 0 "$(curl -s -A "$UA" "$BASE/live03?a=poll" | rg -c secret || echo 0)"
LC="$(header Set-Cookie "$BASE/live03?a=unlock" -X POST -d password=pw | cut -d';' -f1)"
check "poll unlocked note -> 204" 204 "$(poll /live03 "$(sha secret)" -H "Cookie: $LC")"
create code=live04 zone=public mode=burn expiry=never content=boom >/dev/null
check "poll burn note -> 409" 409 "$(poll /live04 -)"
check "burn body not exposed by poll" 0 "$(curl -s -A "$UA" "$BASE/live04?a=poll" | rg -c boom || echo 0)"
check "burn note survives polling" 200 "$(status "$BASE/live04")"
create code=live05 zone=private mode=edit expiry=never content=p >/dev/null
check "poll private note" 204 "$(poll /private/live05 "$(sha p)")"
create code=live06 zone=public mode=edit expiry=1h content=x >/dev/null
EXP="$(CP_DATA_DIR="$WORK/data" php -r '
require "'"$HERE"'/../app/src/lib.php";
$s = new Cp\Store(getenv("CP_DATA_DIR"));
var_export($s->withNote("public", "live06", fn () => true, time() + 7200));')"
check "expired note gone for poll too" "NULL 404" "$EXP $(poll /live06 -)"

echo "--- security review fixes"
create code=polly zone=public mode=edit expiry=never password=pw content=x >/dev/null
for q in '%61=unlock' 'a=x&a=unlock' 'a%00=unlock' 'a=%75nlock' 'a[]=unlock' 'a=Unlock'; do
    check "ambiguous action ?$q -> 400" 400 "$(status -X POST -d password=pw "$BASE/polly?$q")"
done
check "plain ?a=unlock still works" 303 "$(status -X POST -d password=pw "$BASE/polly?a=unlock")"
check "ambiguous poll -> 400" 400 "$(status "$BASE/polly?a=poll&a=poll")"
check "argon2id with OWASP baseline cost" 1 "$(rg -c 'm=19456,t=2,p=1' "$WORK/data/public/polly.json")"
# Hashes made before the cost change (PHP default m=65536,t=4) must keep working.
php -r 'echo password_hash("old", PASSWORD_ARGON2ID);' | F="$WORK/data/public/polly.json" php -r '
$f = getenv("F"); $m = json_decode(file_get_contents($f), true); $m["password"] = trim(stream_get_contents(STDIN));
file_put_contents($f, json_encode($m));'
check "old default-cost hashes still verify" 303 "$(status -X POST -d password=old "$BASE/polly?a=unlock")"
check "invalid UTF-8 on create -> 400" 400 "$(printf 'code=bad8&zone=public&mode=edit&expiry=never&content=%%ff' | curl -s -o /dev/null -w '%{http_code}' -A "$UA" -X POST --data-binary @- "$BASE/new")"
create code=good8 zone=public mode=edit expiry=never content=ok >/dev/null
check "invalid UTF-8 on admin save -> 400" 400 "$(printf 'base=%s&content=%%ff&mode=edit&expiry=never' "$(sha ok)" | curl -s -o /dev/null -w '%{http_code}' -A "$UA" -X POST --data-binary @- "$BASE/new/good8?a=save")"
# Settings link: shown when basic-auth credentials come along (browsers resend them
# site-wide after /new), hidden otherwise; the link target stays behind nginx auth.
check "Settings link on public note with credentials" 1 "$(body -H 'Authorization: Basic eDp4' "$BASE/good8" | rg -c 'href="/new/good8"')"
check "no Settings link on public note without credentials" 0 "$(body "$BASE/good8" | rg -c 'href="/new/good8"' || echo 0)"
check "Share button carries the canonical public path" 1 "$(body "$BASE/good8" | rg -c 'data-share="/good8"')"
: > "$WORK/data/public/emptym.json"
check "empty meta (crash leftover) -> 404, not 500" 404 "$(status "$BASE/emptym")"
check "empty meta is not deleted by readers" 1 "$([[ -f "$WORK/data/public/emptym.json" ]] && echo 1 || echo 0)"
touch -d '2 hours ago' "$WORK/data/public/emptym.json"
CP_DATA_DIR="$WORK/data" php -r 'require "'"$HERE"'/../app/src/lib.php"; (new Cp\Store(getenv("CP_DATA_DIR")))->purgeExpired(time());'
check "purge removes stale empty meta" 0 "$([[ -f "$WORK/data/public/emptym.json" ]] && echo 1 || echo 0)"
check "code usable again after purge" "/emptym" "$(create code=emptym zone=public mode=edit expiry=never content=x)"
if [[ $EUID -eq 0 ]]; then
    # Disk full during create: a 64 KiB tmpfs, filled up, then a 40 KiB note.
    FULL="$WORK/full"; mkdir -p "$FULL"
    mount -t tmpfs -o size=64k tmpfs "$FULL" && mkdir -p "$FULL/public" "$FULL/private"
    head -c 40000 /dev/zero > "$FULL/filler" 2>/dev/null || true
    OUT="$(CP_DATA_DIR="$FULL" php -r '
require "'"$HERE"'/../app/src/lib.php";
$s = new Cp\Store(getenv("CP_DATA_DIR"));
try { @$s->create("public", "fullx", Cp\newMeta("public", "edit", "never", null, time()), str_repeat("x", 40000)); echo "created"; }
catch (Cp\HttpError $e) { echo $e->getCode(); }')"
    check "create on a full disk -> 507" 507 "$OUT"
    check "failed create leaves no files behind" "" "$(ls "$FULL/public")"
    umount "$FULL"
else
    echo "skip disk-full create test (needs root for tmpfs)"
fi

echo "--- entry page gives nothing away"
HOME_HTML="$(body "$BASE/")"
check "no 'note' on entry page" 0 "$(rg -ci 'note' <<< "$HOME_HTML" || echo 0)"
check "no 'paste'/'copy' on entry page" 0 "$(rg -ci 'paste|copy' <<< "$HOME_HTML" || echo 0)"
check "404 page is neutral" 0 "$(body "$BASE/nothere1" | rg -ci 'note|burn|expired|deleted' || echo 0)"
check "animated octopus on entry page" 1 "$(rg -c '<svg class="octo live"' <<< "$HOME_HTML")"
check "small static octopus in the page bar" 1 "$(body "$BASE/nothere1" | rg -c '<a class="brand" href="/"><svg class="octo small"')"
check "favicon is an SVG octopus" 1 "$(body "$BASE/static/favicon.svg" | rg -c 'M20 60C20 18 80 18 80 60Z')"
check "footer on every page" "1 1" "$(body "$BASE/" | rg -c '<footer class="foot">') $(body "$BASE/nothere1" | rg -c '<footer class="foot">')"
check "footer names and links the author" "1 1 1" "$(body "$BASE/" | rg -c 'class="foot-name" href="https://www.juanmitaboada.com"[^>]*>Juanmi Taboada<') $(body "$BASE/" | rg -c 'href="mailto:juanmi@juanmitaboada.com"') $(body "$BASE/" | rg -c 'rel="noopener"')"

echo "--- themes (etc/theme)"
theme_links() { printf '%s\n' "$1" > "$WORK/theme"; body "$BASE/" | rg -o 'href="/static/themes/[^"]*"( media="[^"]*")?' | tr '\n' ' ' | sed 's/ $//'; }
check "no etc/theme -> default" 'href="/static/themes/terminal.css"' "$(rm -f "$WORK/theme"; body "$BASE/" | rg -o 'href="/static/themes/[^"]*"')"
check "single theme" 'href="/static/themes/brutalist.css"' "$(theme_links brutalist)"
check "light/dark pair" 'href="/static/themes/paper.css" media="(prefers-color-scheme: light)" href="/static/themes/night.css" media="(prefers-color-scheme: dark)"' "$(theme_links 'paper night')"
check "comments and blank lines ignored" 'href="/static/themes/crt.css"' "$(theme_links $'# my theme\n\ncrt')"
check "unknown theme -> default" 'href="/static/themes/terminal.css"' "$(theme_links nosuch)"
check "path traversal -> default" 'href="/static/themes/terminal.css"' "$(theme_links '../../etc/passwd')"
check "markup injection -> default" 'href="/static/themes/terminal.css"' "$(theme_links '"><script>x</script>')"
check "one bad name in a pair -> default" 'href="/static/themes/terminal.css"' "$(theme_links 'paper ../x')"
rm -f "$WORK/theme"
for f in "$HERE"/../app/public/static/themes/*.css; do
    n="$(basename "$f" .css)"
    check "theme $n served" 200 "$(status "$BASE/static/themes/$n.css")"
done

echo "--- static"
check "static js served" 200 "$(status "$BASE/static/app.js")"

echo
echo "passed: $PASS  failed: $FAIL"
[[ -s "$WORK/server.log" ]] && rg -i 'warning|error|deprecated' "$WORK/server.log" | rg -v 'Accepted|Closing|\[200\]|\[30|\[40|\[41|\[50' || true
exit $((FAIL > 0))
