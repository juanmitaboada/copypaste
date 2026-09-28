# Security

## Reporting a vulnerability

Please report security issues privately to Juanmi Taboada
<juanmi@juanmitaboada.com> (see [AUTHORS](AUTHORS)), not in public issues. Include the
affected version or commit, the request(s) that reproduce the problem and what an
attacker gains. You will get an answer as soon as possible; please allow time for a fix
before disclosing.

## Audit your installation

`tools/audit.sh` checks one installed instance without changing anything: file
ownership and modes, the data mount options, the php-fpm pool hardening, how nginx
loads the site, the purge timer, the TLS certificate and, over HTTPS, the security
headers and which paths answer.

```sh
date
CP_NAME=cp CP_ROOT=/var/www/cp CP_DOMAIN=copypaste.example.com tools/audit.sh
date
```

Use the same `CP_*` values as in the README install (add `CP_USER`/`CP_GROUP` if they
are not `cp`). It prints `PASS`/`WARN`/`FAIL` per check and exits non-zero on any
`FAIL`. Run it after installing, after every update and from time to time.

## Threat model

cp is reachable by anyone on the Internet. It is designed so that:

- **Visitors** can only read or change what the URL they hold allows: a public note in
  `edit` mode, a `readonly` note, or a single reveal of a burn-after-reading note.
- **Private notes, note creation and settings** (`/private/*`, `/new*`) require HTTP
  basic auth, enforced by nginx before PHP runs.
- **A bug in cp cannot reach the rest of the server**: PHP runs as its own user with
  `open_basedir` limited to its code, its notes and two files in `etc/`, with process,
  network and upload functions disabled; nginx only ever executes one fixed script.
- **Filling the disk only fills cp**: notes live on their own size-capped image mounted
  `noexec,nosuid,nodev`.
- **The entry page does not tell what the site is**, and a wrong code gets the same
  neutral page whether it never existed, expired, was deleted or was already read.

It does **not** protect against:

- **Guessing codes.** A public `edit` note is readable and writable by anyone who guesses
  its code. Short, hand-made codes are guessable; rate limits only slow enumeration down.
  Use `private`, a note password or burn-after-reading for anything sensitive.
- **Reading data on the server.** Note content is stored in clear text. Whoever controls
  the server (or its backups) can read every note.
- **A compromised browser or device** of someone who has the link.

## Hardening in place

| Layer | Measure |
|-------|---------|
| nginx | Fixed URL patterns mapped to one fixed `SCRIPT_FILENAME`; everything else is 404. Codes `[a-z0-9_-]{3,32}` validated in nginx and again in PHP. |
| nginx | `limit_req`: 5 req/s per client (burst 30); password attempts 6/min (burst 3). IPv6 clients are counted per /64. |
| nginx | CSP `default-src 'none'` (no inline script or style), `nosniff`, `Referrer-Policy: same-origin`, `frame-ancestors 'none'`, HSTS, no version in `Server`. |
| nginx | 400 KiB request body limit; the note limit is 256 KiB. |
| PHP | One unambiguous `a=` action parameter: requests where PHP and nginx could read it differently (`%61=`, repeated `a`, encoded values) are rejected, so rate limits and logging always see the real action. |
| PHP | CSRF: POSTs must come from the same origin (`Sec-Fetch-Site`, then `Origin`). This also covers basic-auth pages, whose credentials browsers send cross-site. |
| PHP | Every output escaped; browser-side code only uses `textContent`/`value`. |
| PHP | Note passwords: argon2id (19 MiB, t=2), verified outside the note lock; unlock cookie is an HMAC bound to the note and its password hash, `HttpOnly`, `SameSite=Strict`, `Secure`. |
| PHP | Burn-after-reading: never revealed by GET, HEAD, `?raw` or polling (link previews cannot burn it); read and delete happen under one exclusive lock. |
| PHP | Writes are atomic (temp file + rename); a failed create leaves nothing behind; a full disk returns 507 instead of corrupting a note. |
| PHP | `etc/theme` can only name a stylesheet that exists in `static/themes/`; anything else falls back to the default theme. |
| php-fpm | Dedicated pool and user, `open_basedir`, `disable_functions`, `allow_url_*`/`file_uploads`/`display_errors` off, `clear_env`. |
| systemd | Purge runs as the instance user with `ProtectSystem=strict`, `PrivateNetwork`, `NoNewPrivileges`, write access only to `data/`. |

## Known limitations and recommendations

- **Other PHP sites running as the nginx group.** cp's php-fpm socket and `etc/htpasswd`
  are readable by the nginx group (`www-data`). On Debian the default PHP pool (`www`)
  also runs as `www-data`, so code running there (for example another, compromised PHP
  site on the same server) could read the htpasswd hashes and talk to cp's php-fpm
  socket directly, which is enough to run code as cp's user. Keep every PHP site in its
  own pool with its own user; `tools/audit.sh` warns when a pool runs as the nginx group.
- **Brute force on basic auth.** nginx does not rate-limit failed basic-auth attempts by
  itself. Use strong passwords and fail2ban's stock `nginx-http-auth` jail pointed at
  `/var/log/nginx/<CP_NAME>.error.log`.
- **IPv6 grouping** only applies to addresses written out in their first 64 bits; an
  address compressed there (`2001:db8::1`) is limited on its own.
- **Settings link on public notes** appears whenever the browser sends basic-auth
  credentials, which browsers do for the whole site after you log in to `/new`. nginx
  does not check them on public notes, so anyone can make the link appear by sending an
  `Authorization` header; the link only leads to `/new/<code>`, which nginx protects.
- **Access log**: successful live-update polls (`GET ?a=poll`, 200/204) are not logged,
  to keep the log readable. Everything else, including failed polls, is.

## Security review log

- 2026-09-28: independent review of code and deployment (adversarial, with the real
  nginx config). No critical or high findings. Fixed: parameter pollution that bypassed
  the password rate limit; password verification holding the note lock (a few clients
  could stall reads); requests hidden from the access log behind `a=poll`; IPv6 clients
  rotating addresses within a /64; empty metadata left by a failed create; invalid UTF-8
  from the owner breaking live updates. Documented: the nginx-group limitation and the
  Settings-link behaviour above (a `REMOTE_USER` spoofing finding, harmless by design).
