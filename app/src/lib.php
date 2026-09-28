<?php

declare(strict_types=1);

namespace Cp;

const CODE_RE = '/^[a-z0-9_-]{3,32}$/';
const ZONES = ['public', 'private'];
const MODES = ['edit', 'readonly', 'burn'];
// Codes that collide with routes or would confuse people typing them.
const RESERVED = ['new', 'private', 'priv', 'static', 'go', 'raw', 'favicon'];
const MAX_BYTES = 262144;
const META_VERSION = 1;
const RANDOM_ALPHABET = 'abcdefghjkmnpqrstuvwxyz23456789'; // no i/l/o/0/1: dictable by voice
const RANDOM_LENGTH = 7;
const EXPIRY_OPTIONS = [
    'idle7d' => ['label' => '7 days after last change', 'idle' => 604800, 'ttl' => null],
    '1h' => ['label' => '1 hour', 'idle' => null, 'ttl' => 3600],
    '1d' => ['label' => '1 day', 'idle' => null, 'ttl' => 86400],
    '7d' => ['label' => '7 days', 'idle' => null, 'ttl' => 604800],
    'never' => ['label' => 'Never', 'idle' => null, 'ttl' => null],
];
const DEFAULT_EXPIRY = ['public' => 'idle7d', 'private' => 'never'];
const THEME_RE = '/^[a-z0-9-]{1,32}$/';
const DEFAULT_THEME = 'terminal';

final class HttpError extends \RuntimeException
{
}

final class Config
{
    public function __construct(
        public readonly string $dataDir,
        public readonly string $secretFile,
        public readonly string $themeFile = '',
        public readonly string $themesDir = '',
    ) {
    }

    public static function fromEnvironment(): self
    {
        // Defaults derive from the install layout (<root>/app/src) so nothing is host-specific.
        $root = \dirname(__DIR__, 2);
        $dataDir = self::env('CP_DATA_DIR') ?? $root . '/data';
        $secretFile = self::env('CP_SECRET_FILE') ?? $root . '/etc/secret';
        $themeFile = self::env('CP_THEME_FILE') ?? $root . '/etc/theme';
        return new self(rtrim($dataDir, '/'), $secretFile, $themeFile, \dirname(__DIR__) . '/public/static/themes');
    }

    /**
     * Themes named in etc/theme: one name, or "light dark" to follow the visitor's
     * system preference. Anything invalid or missing falls back to DEFAULT_THEME,
     * so the file can never point outside static/themes/.
     *
     * @return list<string>
     */
    public function themes(): array
    {
        $raw = $this->themeFile === '' ? false : @file_get_contents($this->themeFile, false, null, 0, 256);
        $names = [];
        if (\is_string($raw)) {
            foreach (preg_split('/\R/', $raw) ?: [] as $line) {
                $line = trim((string) preg_replace('/#.*/', '', $line));
                if ($line !== '') {
                    $names = preg_split('/\s+/', $line) ?: [];
                    break;
                }
            }
        }
        $valid = [];
        foreach (\array_slice($names, 0, 2) as $name) {
            if (preg_match(THEME_RE, $name) !== 1 || !is_file($this->themesDir . '/' . $name . '.css')) {
                return [DEFAULT_THEME];
            }
            $valid[] = $name;
        }
        return $valid === [] ? [DEFAULT_THEME] : $valid;
    }

    private static function env(string $name): ?string
    {
        $value = $_SERVER[$name] ?? getenv($name);
        return \is_string($value) && $value !== '' ? $value : null;
    }

    public function secret(): string
    {
        $secret = @file_get_contents($this->secretFile);
        if ($secret === false || \strlen(trim($secret)) < 32) {
            throw new \RuntimeException('Secret file missing or too short: ' . $this->secretFile);
        }
        return trim($secret);
    }
}

final class Note
{
    /** @param array<string, mixed> $meta */
    public function __construct(
        public readonly string $zone,
        public readonly string $code,
        public array $meta,
        public string $content,
    ) {
    }

    public function hash(): string
    {
        return hash('sha256', $this->content);
    }

    public function mode(): string
    {
        return (string) $this->meta['mode'];
    }

    public function hasPassword(): bool
    {
        return \is_string($this->meta['password'] ?? null);
    }

    public function isExpired(int $now): bool
    {
        $expiresAt = $this->meta['expires_at'] ?? null;
        $idle = $this->meta['idle'] ?? null;
        if (\is_int($expiresAt) && $now >= $expiresAt) {
            return true;
        }
        return \is_int($idle) && $now >= (int) $this->meta['updated_at'] + $idle;
    }

    public function path(): string
    {
        return notePath($this->zone, $this->code);
    }
}

function validCode(string $code): bool
{
    return preg_match(CODE_RE, $code) === 1;
}

function validZone(string $zone): bool
{
    return \in_array($zone, ZONES, true);
}

function notePath(string $zone, string $code): string
{
    return ($zone === 'private' ? '/private/' : '/') . $code;
}

/** @return array<string, mixed> */
function newMeta(string $zone, string $mode, string $expiry, ?string $passwordHash, int $now): array
{
    $option = EXPIRY_OPTIONS[$expiry];
    return [
        'v' => META_VERSION,
        'zone' => $zone,
        'mode' => $mode,
        'created_at' => $now,
        'updated_at' => $now,
        'expiry' => $expiry,
        'idle' => $option['idle'],
        'expires_at' => $option['ttl'] === null ? null : $now + $option['ttl'],
        'password' => $passwordHash,
    ];
}

/** @param array<string, mixed> $meta */
function applyExpiry(array &$meta, string $expiry, int $now): void
{
    $option = EXPIRY_OPTIONS[$expiry];
    $meta['expiry'] = $expiry;
    $meta['idle'] = $option['idle'];
    $meta['expires_at'] = $option['ttl'] === null ? null : $now + $option['ttl'];
}

function hashPassword(string $password): string
{
    if (!\defined('PASSWORD_ARGON2ID')) {
        return password_hash($password, PASSWORD_BCRYPT);
    }
    // OWASP's argon2id baseline (19 MiB, t=2, p=1): PHP's default (64 MiB, t=4)
    // costs ~200 ms and 64 MiB per attempt, which a 5-worker pool cannot afford.
    return password_hash($password, PASSWORD_ARGON2ID, ['memory_cost' => 19456, 'time_cost' => 2, 'threads' => 1]);
}

function randomCode(): string
{
    $out = '';
    $max = \strlen(RANDOM_ALPHABET) - 1;
    for ($i = 0; $i < RANDOM_LENGTH; $i++) {
        $out .= RANDOM_ALPHABET[random_int(0, $max)];
    }
    return $out;
}

/**
 * File layout: <data>/<zone>/<code>.json (meta) + <code>.txt (content).
 * Every access holds flock() on the .json handle; a waiter that wakes up on an
 * unlinked inode (nlink == 0) treats the note as gone, which makes delete and
 * burn-after-read race-free.
 */
final class Store
{
    public function __construct(private readonly string $dataDir)
    {
    }

    private function base(string $zone, string $code): string
    {
        if (!validZone($zone) || !validCode($code)) {
            throw new \InvalidArgumentException('Invalid zone or code');
        }
        return $this->dataDir . '/' . $zone . '/' . $code;
    }

    public function exists(string $zone, string $code): bool
    {
        return is_file($this->base($zone, $code) . '.json');
    }

    public function existsInAnyZone(string $code): bool
    {
        foreach (ZONES as $zone) {
            if ($this->exists($zone, $code)) {
                return true;
            }
        }
        return false;
    }

    /** @param array<string, mixed> $meta */
    public function create(string $zone, string $code, array $meta, string $content): bool
    {
        $base = $this->base($zone, $code);
        $fh = @fopen($base . '.json', 'x'); // 'x' fails if it exists: atomic create
        if ($fh === false) {
            return false;
        }
        try {
            flock($fh, LOCK_EX);
            $meta['hash'] = hash('sha256', $content);
            $json = json_encode($meta, JSON_THROW_ON_ERROR | JSON_PRETTY_PRINT) . "\n";
            try {
                $this->writeContent($base, $content);
                if (fwrite($fh, $json) !== \strlen($json) || !fflush($fh)) {
                    throw new HttpError('Storage full or not writable', 507);
                }
            } catch (\Throwable $e) {
                // Never leave a half-created note behind: it would block the code forever.
                @unlink($base . '.txt');
                @unlink($base . '.json');
                throw $e;
            }
        } finally {
            flock($fh, LOCK_UN);
            fclose($fh);
        }
        return true;
    }

    /**
     * Run $fn with the note locked. Returns null when the note does not exist or
     * has expired (expired notes are deleted on the spot).
     *
     * @template T
     * @param callable(Note, \Closure(Note): void, \Closure(): void): T $fn  receives (note, save, delete)
     * @return T|null
     */
    public function withNote(string $zone, string $code, callable $fn, ?int $now = null): mixed
    {
        $base = $this->base($zone, $code);
        $fh = @fopen($base . '.json', 'r+');
        if ($fh === false) {
            return null;
        }
        $now ??= time();
        try {
            // Always exclusive: expiry/burn may delete, and contention is negligible here.
            flock($fh, LOCK_EX);
            $stat = fstat($fh);
            if ($stat === false || $stat['nlink'] === 0) {
                return null;
            }
            $raw = stream_get_contents($fh, -1, 0);
            if ($raw === '' || $raw === false) {
                // Being created right now (create() writes it under this same lock) or
                // left by a crash; purgeExpired() removes stale ones. Never delete here.
                return null;
            }
            $meta = json_decode($raw, true, 8, JSON_THROW_ON_ERROR);
            $content = @file_get_contents($base . '.txt');
            if (!\is_array($meta) || $content === false) {
                throw new \RuntimeException('Corrupt note: ' . $zone . '/' . $code);
            }
            $note = new Note($zone, $code, $meta, $content);
            $delete = function () use ($base): void {
                @unlink($base . '.txt');
                @unlink($base . '.json');
            };
            if ($note->isExpired($now)) {
                $delete();
                return null;
            }
            $save = function (Note $n) use ($fh, $base, $now): void {
                $n->meta['updated_at'] = $now;
                $n->meta['hash'] = $n->hash();
                $json = json_encode($n->meta, JSON_THROW_ON_ERROR | JSON_PRETTY_PRINT) . "\n";
                $this->writeContent($base, $n->content);
                // Overwrite in place, then trim: meta stays inside its first block, so
                // this needs no new disk space and cannot hit ENOSPC (truncating first could).
                rewind($fh);
                if (fwrite($fh, $json) !== \strlen($json) || !ftruncate($fh, \strlen($json)) || !fflush($fh)) {
                    throw new HttpError('Storage full or not writable', 507);
                }
            };
            return $fn($note, $save, $delete);
        } finally {
            flock($fh, LOCK_UN);
            fclose($fh);
        }
    }

    private function writeContent(string $base, string $content): void
    {
        // tmp + rename: the .txt is never observed half-written, even after a crash.
        $tmp = $base . '.txt.' . bin2hex(random_bytes(6)) . '.tmp';
        if (file_put_contents($tmp, $content) === false || !rename($tmp, $base . '.txt')) {
            @unlink($tmp);
            throw new HttpError('Storage full or not writable', 507);
        }
    }

    /** @return list<array{zone: string, code: string, meta: array<string, mixed>, size: int}> */
    public function list(): array
    {
        $out = [];
        foreach (ZONES as $zone) {
            foreach (glob($this->dataDir . '/' . $zone . '/*.json') ?: [] as $file) {
                $code = basename($file, '.json');
                if (!validCode($code)) {
                    continue;
                }
                $meta = json_decode((string) @file_get_contents($file), true);
                if (!\is_array($meta)) {
                    continue;
                }
                $size = (int) @filesize($this->dataDir . '/' . $zone . '/' . $code . '.txt');
                $out[] = ['zone' => $zone, 'code' => $code, 'meta' => $meta, 'size' => $size];
            }
        }
        usort($out, static fn (array $a, array $b): int => $b['meta']['updated_at'] <=> $a['meta']['updated_at']);
        return $out;
    }

    public function purgeExpired(int $now): int
    {
        $purged = 0;
        // Empty meta older than an hour can only be the remains of a crash mid-create.
        foreach (ZONES as $zone) {
            foreach (glob($this->dataDir . '/' . $zone . '/*.json') ?: [] as $file) {
                $st = @stat($file);
                if ($st !== false && $st['size'] === 0 && $st['mtime'] < $now - 3600) {
                    @unlink(substr($file, 0, -5) . '.txt');
                    @unlink($file);
                    $purged++;
                }
            }
        }
        foreach ($this->list() as $item) {
            $found = $this->withNote($item['zone'], $item['code'], static fn (): bool => true, $now);
            if ($found === null) {
                $purged++;
            }
        }
        return $purged;
    }

    public function freeBytes(): ?int
    {
        $free = @disk_free_space($this->dataDir);
        return $free === false ? null : (int) $free;
    }
}

final class Unlock
{
    public function __construct(private readonly string $secret)
    {
    }

    public static function cookieName(Note $note): string
    {
        return 'cp_' . $note->zone . '_' . $note->code;
    }

    public function token(Note $note): string
    {
        // Bound to the password hash: changing the password invalidates old cookies.
        return hash_hmac('sha256', $note->zone . '|' . $note->code . '|' . (string) $note->meta['password'], $this->secret);
    }

    /** @param array<string, string> $cookies */
    public function isUnlocked(Note $note, array $cookies): bool
    {
        if (!$note->hasPassword()) {
            return true;
        }
        $given = $cookies[self::cookieName($note)] ?? '';
        return \is_string($given) && hash_equals($this->token($note), $given);
    }
}
