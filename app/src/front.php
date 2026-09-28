<?php

declare(strict_types=1);

// Single PHP entry point. nginx maps each allowed URL to this file and passes
// CP_ROUTE / CP_ZONE / CP_CODE; nothing else under the web root is executable.

namespace Cp;

require __DIR__ . '/lib.php';
require __DIR__ . '/views.php';

final class Response
{
    /** @param array<string, string> $headers */
    public function __construct(
        public int $status = 200,
        public string $body = '',
        public array $headers = [],
    ) {
    }

    public static function html(string $body, int $status = 200): self
    {
        return new self($status, $body, ['Content-Type' => 'text/html; charset=utf-8']);
    }

    public static function text(string $body, int $status = 200): self
    {
        return new self($status, $body, ['Content-Type' => 'text/plain; charset=utf-8']);
    }

    /** @param array<string, mixed> $data */
    public static function json(array $data, int $status = 200): self
    {
        return new self($status, json_encode($data, JSON_THROW_ON_ERROR), ['Content-Type' => 'application/json']);
    }

    public static function redirect(string $location): self
    {
        return new self(303, '', ['Location' => $location]);
    }

    public function send(): void
    {
        http_response_code($this->status);
        header('Cache-Control: no-store');
        header('X-Robots-Tag: noindex, nofollow');
        foreach ($this->headers as $k => $v) {
            header($k . ': ' . $v);
        }
        echo $this->body;
    }
}

final class App
{
    private Store $store;
    private int $now;

    public function __construct(private readonly Config $config)
    {
        View\themes($config->themes());
        $this->store = new Store($config->dataDir);
        $this->now = time();
    }

    public function handle(): Response
    {
        $method = (string) ($_SERVER['REQUEST_METHOD'] ?? 'GET');
        if (!\in_array($method, ['GET', 'HEAD', 'POST'], true)) {
            return Response::text("Method not allowed\n", 405);
        }
        if ($method === 'POST' && !$this->sameOrigin()) {
            return Response::text("Cross-site request refused\n", 403);
        }
        $route = (string) ($_SERVER['CP_ROUTE'] ?? '');
        $zone = (string) ($_SERVER['CP_ZONE'] ?? 'public');
        $code = (string) ($_SERVER['CP_CODE'] ?? '');
        $action = self::action((string) ($_SERVER['QUERY_STRING'] ?? ''));
        if ($action === null) {
            return Response::text("Bad request\n", 400);
        }

        // Defense in depth: nginx already constrains these, but never trust one layer.
        if (\in_array($route, ['note', 'admin'], true) && (!validZone($zone) || !validCode($code))) {
            return $this->notFound();
        }
        return match ($route) {
            'home' => Response::html(View\home()),
            'go' => $this->go(),
            'note' => $method === 'POST' ? $this->notePost($zone, $code, $action) : $this->noteGet($zone, $code, $action),
            'new' => $method === 'POST' ? $this->createNote() : $this->newForm([], ''),
            'admin' => $method === 'POST' ? $this->adminPost($zone, $code, $action) : $this->adminGet($zone, $code),
            default => $this->notFound(),
        };
    }

    /**
     * The action parameter, or null when it is ambiguous. nginx rate-limits and
     * logs by $arg_a (first raw "a"), while PHP takes the last one and decodes
     * keys and values ("%61=unlock", "a=x&a=unlock", "a=%75nlock" all mean
     * "unlock" to PHP). Accepting only one literal a=[a-z]+ keeps both views equal.
     */
    public static function action(string $query): ?string
    {
        $found = null;
        foreach (explode('&', $query) as $pair) {
            if ($pair === '') {
                continue;
            }
            parse_str($pair, $parsed);
            if (!\array_key_exists('a', $parsed)) {
                continue;
            }
            [$key, $value] = array_pad(explode('=', $pair, 2), 2, null);
            if ($found !== null || $key !== 'a' || $value === null || preg_match('/^[a-z]{1,16}$/', $value) !== 1) {
                return null;
            }
            $found = $value;
        }
        return $found ?? '';
    }

    /**
     * Browsers send Sec-Fetch-Site and/or Origin on POST; basic-auth credentials
     * are attached cross-site too, so this is the CSRF guard for /private and /new.
     * curl sends neither and is allowed.
     */
    private function sameOrigin(): bool
    {
        // Sec-Fetch-Site is set by the browser itself and cannot be forged by page
        // script, so when present it decides. Origin alone is not enough: form
        // navigations may carry "Origin: null" (e.g. under a no-referrer policy).
        $site = $_SERVER['HTTP_SEC_FETCH_SITE'] ?? null;
        if (\is_string($site)) {
            return \in_array($site, ['same-origin', 'none'], true);
        }
        $origin = $_SERVER['HTTP_ORIGIN'] ?? null;
        if (\is_string($origin) && $origin !== 'null') {
            return strcasecmp($origin, $this->scheme() . '://' . $this->host()) === 0;
        }
        return !\is_string($origin);
    }

    private function scheme(): string
    {
        return (($_SERVER['HTTPS'] ?? '') === 'on') ? 'https' : 'http';
    }

    private function host(): string
    {
        // SERVER_NAME comes from nginx's server_name, not from the client's Host header.
        return (string) ($_SERVER['SERVER_NAME'] ?? 'localhost') . $this->portSuffix();
    }

    private function portSuffix(): string
    {
        $port = (string) ($_SERVER['SERVER_PORT'] ?? '');
        $default = $this->scheme() === 'https' ? '443' : '80';
        return ($port === '' || $port === $default) ? '' : ':' . $port;
    }

    private function notFound(): Response
    {
        // One neutral message for every case: it never tells whether a code existed,
        // nor what kind of site this is (it is reachable from the entry page).
        return Response::html(View\message('Nothing here', ''), 404);
    }

    private function go(): Response
    {
        $input = strtolower(trim(\is_string($_GET['c'] ?? null) ? $_GET['c'] : ''));
        $zone = 'public';
        foreach (['priv/', 'private/'] as $prefix) {
            if (str_starts_with($input, $prefix)) {
                $zone = 'private';
                $input = substr($input, \strlen($prefix));
                break;
            }
        }
        if (!validCode($input)) {
            return Response::html(View\home('That is not a valid code.', \is_string($_GET['c'] ?? null) ? $_GET['c'] : ''), 400);
        }
        // No existence check here: /private/* sits behind auth, and the public 404 is served by the note route.
        return Response::redirect(notePath($zone, $input));
    }

    private function wantsRaw(): bool
    {
        if (\array_key_exists('raw', $_GET)) {
            return true;
        }
        $ua = (string) ($_SERVER['HTTP_USER_AGENT'] ?? '');
        return str_starts_with($ua, 'curl/') || str_starts_with($ua, 'Wget/');
    }

    private function unlocker(): Unlock
    {
        return new Unlock($this->config->secret());
    }

    private function noteGet(string $zone, string $code, string $action): Response
    {
        if ($action === 'poll') {
            return $this->poll($zone, $code);
        }
        $raw = $this->wantsRaw();
        $res = $this->store->withNote($zone, $code, function (Note $note) use ($raw): Response {
            if (!$this->unlocker()->isUnlocked($note, $_COOKIE)) {
                return $raw ? Response::text("Password required\n", 403) : Response::html(View\unlock($note));
            }
            if ($note->mode() === 'burn') {
                // A GET never burns: link previewers (chat apps) prefetch URLs.
                return $raw ? Response::text("Burn-after-reading note: POST ?a=reveal&raw\n", 409) : Response::html(View\burnConfirm($note));
            }
            if ($raw) {
                return Response::text($note->content);
            }
            return Response::html(View\editor($note, $note->mode() !== 'edit', $this->isPrivateArea()));
        }, $this->now);
        return $res ?? ($raw ? Response::text("Not found\n", 404) : $this->notFound());
    }

    /**
     * Live-update check for open pages. The client sends the hash it holds in
     * X-CP-Base; 204 means unchanged, 200 carries the new content. A GET, so it
     * needs no CSRF check and never modifies anything.
     */
    private function poll(string $zone, string $code): Response
    {
        $res = $this->store->withNote($zone, $code, function (Note $note): Response {
            if (!$this->unlocker()->isUnlocked($note, $_COOKIE)) {
                return Response::json(['error' => 'locked'], 403);
            }
            if ($note->mode() === 'burn') {
                // Polling must never expose a burn-after-reading note.
                return Response::json(['error' => 'burn'], 409);
            }
            $base = $_SERVER['HTTP_X_CP_BASE'] ?? '';
            if (\is_string($base) && hash_equals($note->hash(), $base)) {
                return new Response(204);
            }
            return Response::json(['hash' => $note->hash(), 'content' => $note->content]);
        }, $this->now);
        return $res ?? Response::json(['error' => 'not_found'], 404);
    }

    /**
     * Whether to show the Settings link: on private notes, and on public ones when
     * the browser sends basic-auth credentials (after logging in to /new it sends
     * them for the whole site). On public locations nginx does not verify them, so
     * anyone can make the link appear; that is harmless because the link only
     * leads to /new/<code>, which nginx does protect.
     */
    private function isPrivateArea(): bool
    {
        return ($_SERVER['CP_ZONE'] ?? '') === 'private' || (string) ($_SERVER['REMOTE_USER'] ?? '') !== '';
    }

    private function notePost(string $zone, string $code, string $action): Response
    {
        // reveal/unlock are HTML form submissions (a reload re-POSTs them), so they
        // answer with pages; save/delete are fetch() calls from app.js and get JSON.
        $isForm = \in_array($action, ['reveal', 'unlock'], true);
        $raw = $this->wantsRaw();
        if ($action === 'unlock') {
            // Copy the note out under the lock, verify the password after releasing
            // it: argon2 is slow and must not block readers of the same note.
            $note = $this->store->withNote($zone, $code, fn (Note $n): Note => $n, $this->now);
            if ($note === null) {
                return $raw ? Response::text("Not found\n", 404) : $this->notFound();
            }
            return $this->unlock($note);
        }
        $res = $this->store->withNote($zone, $code, function (Note $note, \Closure $save, \Closure $delete) use ($action, $isForm, $raw): Response {
            if (!$this->unlocker()->isUnlocked($note, $_COOKIE)) {
                if ($isForm) {
                    return $raw ? Response::text("Password required\n", 403) : Response::html(View\unlock($note), 403);
                }
                return Response::json(['error' => 'locked'], 403);
            }
            return match ($action) {
                'save' => $this->save($note, $save),
                'delete' => $this->deleteByVisitor($note, $delete),
                'reveal' => $this->reveal($note, $delete),
                default => Response::text("Unknown action\n", 400),
            };
        }, $this->now);
        if ($res !== null) {
            return $res;
        }
        if ($isForm) {
            return $raw ? Response::text("Not found\n", 404) : $this->notFound();
        }
        return Response::json(['error' => 'not_found'], 404);
    }

    private function unlock(Note $note): Response
    {
        $password = \is_string($_POST['password'] ?? null) ? $_POST['password'] : '';
        if (!$note->hasPassword() || !password_verify($password, (string) $note->meta['password'])) {
            return Response::html(View\unlock($note, 'Wrong password.'), 403);
        }
        $this->grantUnlock($note);
        return Response::redirect($note->path());
    }

    private function grantUnlock(Note $note): void
    {
        setcookie(Unlock::cookieName($note), $this->unlocker()->token($note), [
            'path' => $note->path(),
            'secure' => $this->scheme() === 'https',
            'httponly' => true,
            'samesite' => 'Strict',
        ]);
    }

    /**
     * Where the owner lands after creating or saving from /new. Editable notes open
     * in the editor, which live-updates; read-only and burn notes stay on the
     * settings page (opening a burn note there would only show its confirm step).
     */
    private function afterOwnerSave(Note $note, string $notice): Response
    {
        if ($note->mode() !== 'edit') {
            return Response::redirect('/new' . $note->path() . '?' . $notice . '=1');
        }
        if ($note->hasPassword()) {
            // The owner just set it: do not make them type it again.
            $this->grantUnlock($note);
        }
        return Response::redirect($note->path());
    }

    private function readBody(): ?string
    {
        $in = fopen('php://input', 'rb');
        if ($in === false) {
            return '';
        }
        // Read one byte past the limit to detect oversize without buffering unbounded input.
        $body = stream_get_contents($in, MAX_BYTES + 1);
        fclose($in);
        $body = $body === false ? '' : $body;
        return \strlen($body) > MAX_BYTES ? null : $body;
    }

    private function save(Note $note, \Closure $save): Response
    {
        if ($note->mode() !== 'edit') {
            return Response::json(['error' => 'read_only'], 403);
        }
        $body = $this->readBody();
        if ($body === null) {
            return Response::json(['error' => 'too_large', 'max' => MAX_BYTES], 413);
        }
        if (preg_match('//u', $body) !== 1) { // UTF-8 check without requiring mbstring
            return Response::json(['error' => 'not_utf8'], 400);
        }
        // Browsers always send the hash they started from; curl may omit it (last writer wins).
        $base = $_SERVER['HTTP_X_CP_BASE'] ?? null;
        if (\is_string($base) && !hash_equals($note->hash(), $base)) {
            return Response::json(['error' => 'conflict', 'hash' => $note->hash()], 409);
        }
        $note->content = $body;
        $save($note);
        return Response::json(['hash' => $note->hash(), 'size' => \strlen($body)]);
    }

    private function deleteByVisitor(Note $note, \Closure $delete): Response
    {
        if ($note->mode() !== 'edit') {
            return Response::json(['error' => 'read_only'], 403);
        }
        $delete();
        return Response::json(['deleted' => true]);
    }

    private function reveal(Note $note, \Closure $delete): Response
    {
        if ($note->mode() !== 'burn') {
            return Response::text("Not a burn-after-reading note\n", 400);
        }
        // Read and delete happen under the same exclusive lock: a second reader gets 404.
        $delete();
        return \array_key_exists('raw', $_GET) ? Response::text($note->content) : Response::html(View\burnRevealed($note));
    }

    /** @param array<string, string> $values */
    private function newForm(array $values, string $error, int $status = 200): Response
    {
        $values += ['zone' => 'public', 'mode' => 'edit'];
        $values += ['expiry' => DEFAULT_EXPIRY[$values['zone']] ?? 'never'];
        return Response::html(View\adminNew($this->store->list(), $values, $error, $this->store->freeBytes()), $status);
    }

    private function createNote(): Response
    {
        $v = [];
        foreach (['code', 'zone', 'mode', 'expiry', 'password', 'content'] as $k) {
            $v[$k] = \is_string($_POST[$k] ?? null) ? $_POST[$k] : '';
        }
        $v['code'] = strtolower(trim($v['code']));
        $formValues = $v;
        unset($formValues['password']); // never echo a password back into the page
        if (!validZone($v['zone']) || !\in_array($v['mode'], MODES, true) || !\array_key_exists($v['expiry'], EXPIRY_OPTIONS)) {
            return $this->newForm($formValues, 'Invalid form values.', 400);
        }
        $content = str_replace("\r\n", "\n", $v['content']);
        if (preg_match('//u', $content) !== 1) {
            return $this->newForm($formValues, 'Content must be UTF-8 text.', 400);
        }
        if (\strlen($content) > MAX_BYTES) {
            return $this->newForm($formValues, 'Content is larger than ' . View\humanBytes(MAX_BYTES) . '.', 413);
        }
        if ($v['mode'] === 'burn' && $content === '') {
            return $this->newForm($formValues, 'A burn-after-reading note needs content.', 400);
        }
        $random = $v['code'] === '';
        for ($attempt = 0; $attempt < 20; $attempt++) {
            $code = $random ? randomCode() : $v['code'];
            if (!validCode($code)) {
                return $this->newForm($formValues, 'Codes use a–z, 0–9, _ and -, 3–32 characters.', 400);
            }
            if (\in_array($code, RESERVED, true)) {
                return $this->newForm($formValues, 'That code is reserved.', 400);
            }
            // Codes are unique across zones so "priv/" is the only thing that selects the zone.
            if ($this->store->existsInAnyZone($code)) {
                if ($random) {
                    continue;
                }
                return $this->newForm($formValues, 'That code is already in use.', 409);
            }
            $hash = $v['password'] === '' ? null : hashPassword($v['password']);
            $meta = newMeta($v['zone'], $v['mode'], $v['expiry'], $hash, $this->now);
            if ($this->store->create($v['zone'], $code, $meta, $content)) {
                return $this->afterOwnerSave(new Note($v['zone'], $code, $meta, $content), 'created');
            }
        }
        return $this->newForm($formValues, 'Could not allocate a code, try again.', 500);
    }

    private function adminGet(string $zone, string $code): Response
    {
        $notice = \array_key_exists('created', $_GET) ? 'Note created.' : (\array_key_exists('saved', $_GET) ? 'Saved.' : '');
        $res = $this->store->withNote($zone, $code, fn (Note $note): Response
            => Response::html(View\adminNote($note, $this->scheme(), $this->host(), '', $notice)), $this->now);
        return $res ?? $this->notFound();
    }

    private function adminPost(string $zone, string $code, string $action): Response
    {
        $res = $this->store->withNote($zone, $code, function (Note $note, \Closure $save, \Closure $delete) use ($action): Response {
            if ($action === 'delete') {
                $delete();
                return Response::redirect('/new');
            }
            if ($action !== 'save') {
                return Response::text("Unknown action\n", 400);
            }
            $content = str_replace("\r\n", "\n", \is_string($_POST['content'] ?? null) ? $_POST['content'] : '');
            $fail = fn (string $msg, int $status): Response
                => Response::html(View\adminNote($note, $this->scheme(), $this->host(), $msg, '', $content), $status);
            $base = \is_string($_POST['base'] ?? null) ? $_POST['base'] : '';
            if (!hash_equals($note->hash(), $base)) {
                return $fail('The note changed since you opened it. Your text is below; copy it and reload.', 409);
            }
            $mode = \is_string($_POST['mode'] ?? null) ? $_POST['mode'] : '';
            $expiry = \is_string($_POST['expiry'] ?? null) ? $_POST['expiry'] : '';
            if (!\in_array($mode, MODES, true) || !\array_key_exists($expiry, EXPIRY_OPTIONS)) {
                return $fail('Invalid form values.', 400);
            }
            if (preg_match('//u', $content) !== 1) {
                return $fail('Content must be UTF-8 text.', 400);
            }
            if (\strlen($content) > MAX_BYTES) {
                return $fail('Content is larger than ' . View\humanBytes(MAX_BYTES) . '.', 413);
            }
            if ($mode === 'burn' && $content === '') {
                return $fail('A burn-after-reading note needs content.', 400);
            }
            $password = \is_string($_POST['password'] ?? null) ? $_POST['password'] : '';
            $pwAction = \is_string($_POST['password_action'] ?? null) ? $_POST['password_action'] : ($password === '' ? 'keep' : 'set');
            if ($pwAction === 'set' && $password === '') {
                return $fail('Enter the new password.', 400);
            }
            $note->content = $content;
            $note->meta['mode'] = $mode;
            applyExpiry($note->meta, $expiry, $this->now);
            if ($pwAction === 'set') {
                $note->meta['password'] = hashPassword($password);
            } elseif ($pwAction === 'clear') {
                $note->meta['password'] = null;
            }
            $save($note);
            return $this->afterOwnerSave($note, 'saved');
        }, $this->now);
        return $res ?? $this->notFound();
    }
}

try {
    (new App(Config::fromEnvironment()))->handle()->send();
} catch (HttpError $e) {
    Response::text($e->getMessage() . "\n", $e->getCode())->send();
} catch (\Throwable $e) {
    error_log('cp: ' . $e);
    Response::text("Internal error\n", 500)->send();
}
