<?php

declare(strict_types=1);

namespace Cp\View;

use Cp\Note;

use const Cp\DEFAULT_THEME;
use const Cp\EXPIRY_OPTIONS;
use const Cp\MAX_BYTES;
use const Cp\MODES;

const AUTHOR = 'Juanmi Taboada';
const AUTHOR_URL = 'https://www.juanmitaboada.com';
const AUTHOR_EMAIL = 'juanmi@juanmitaboada.com';

function h(string $s): string
{
    return htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

/**
 * Active theme(s), set once per request from etc/theme (see Config::themes()).
 *
 * @param list<string>|null $set
 * @return list<string>
 */
function themes(?array $set = null): array
{
    static $themes = [DEFAULT_THEME];
    if ($set !== null) {
        $themes = $set;
    }
    return $themes;
}

/** Small inline icons (Tabler-style strokes); inline SVG needs no CSP exception. */
function icon(string $name): string
{
    $paths = [
        'globe' => '<circle cx="12" cy="12" r="9"/><path d="M3.6 9h16.8M3.6 15h16.8M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18"/>',
        'mail' => '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>',
    ];
    return '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' . $paths[$name] . '</svg>';
}

function footer(): string
{
    $url = h(AUTHOR_URL);
    $mail = h(AUTHOR_EMAIL);
    return '<footer class="foot">'
        . '<span class="foot-year">© 2026</span>'
        . '<a class="foot-name" href="' . $url . '" target="_blank" rel="noopener">' . h(AUTHOR) . '</a>'
        . '<span class="foot-links">'
        . '<a href="' . $url . '" target="_blank" rel="noopener" title="Website">' . icon('globe') . '<span>' . h(preg_replace('#^https?://(www\.)?#', '', AUTHOR_URL)) . '</span></a>'
        . '<a href="mailto:' . $mail . '" title="Email">' . icon('mail') . '<span>' . $mail . '</span></a>'
        . '</span></footer>';
}

function themeLinks(): string
{
    $t = themes();
    if (\count($t) === 1) {
        return '<link rel="stylesheet" href="/static/themes/' . h($t[0]) . '.css">';
    }
    // "light dark" pair: the browser applies whichever matches the system preference.
    return '<link rel="stylesheet" href="/static/themes/' . h($t[0]) . '.css" media="(prefers-color-scheme: light)">' . "\n"
        . '<link rel="stylesheet" href="/static/themes/' . h($t[1]) . '.css" media="(prefers-color-scheme: dark)">';
}

/** @param array<string, string> $data  rendered as data-* on <body> for app.js (CSP forbids inline JS) */
function layout(string $title, string $body, array $data = []): string
{
    $attrs = '';
    foreach ($data as $k => $v) {
        $attrs .= ' data-' . h($k) . '="' . h($v) . '"';
    }
    $t = h($title);
    $theme = themeLinks();
    $foot = footer();
    return <<<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>{$t}</title>
<link rel="icon" href="/static/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/static/style.css">
{$theme}
<script src="/static/app.js" defer></script>
</head>
<body{$attrs}>
{$body}
{$foot}
</body>
</html>
HTML;
}

/**
 * The octopus logo, inline so it takes the theme's colours (CSS variables).
 * "live" adds the CSS animation, which style.css drops for prefers-reduced-motion.
 */
function octopus(string $class): string
{
    return '<svg class="octo ' . h($class) . '" viewBox="0 0 100 100" aria-hidden="true" focusable="false">'
        . '<g class="arms"><path d="M28 58q-6 14-2 26"/><path d="M42 62q-2 14-6 26"/>'
        . '<path d="M58 62q2 14 6 26"/><path d="M72 58q6 14 2 26"/></g>'
        . '<path class="head" d="M20 60C20 18 80 18 80 60Z"/>'
        . '<circle class="eye" cx="40" cy="44" r="6"/><circle class="eye" cx="60" cy="44" r="6"/>'
        . '<circle class="pupil" cx="41" cy="45" r="3"/><circle class="pupil" cx="61" cy="45" r="3"/>'
        . '<circle class="cheek" cx="32" cy="54" r="3"/><circle class="cheek" cx="68" cy="54" r="3"/>'
        . '</svg>';
}

function crumbs(?Note $note, string $extra = ''): string
{
    $out = '<a class="brand" href="/">' . octopus('small') . 'cp</a>';
    if ($note !== null) {
        $out .= '<span class="sep">/</span><span class="code">' . h($note->code) . '</span>'
            . '<span class="badge badge-' . h($note->zone) . '">' . h($note->zone) . '</span>';
        if ($note->mode() !== 'edit') {
            $out .= '<span class="badge badge-mode">' . h($note->mode() === 'burn' ? 'burn after reading' : 'read-only') . '</span>';
        }
        if ($note->hasPassword()) {
            $out .= '<span class="badge badge-mode">password</span>';
        }
    }
    return '<div class="bar">' . $out . $extra . '</div>';
}

function home(string $error = '', string $value = ''): string
{
    $err = $error === '' ? '' : '<p class="error">' . h($error) . '</p>';
    $v = h($value);
    // Deliberately says nothing about what this is: just the name, a field and "+".
    $octo = octopus('live');
    $body = <<<HTML
<main class="center home">
  <a class="newlink" href="/new" aria-label="New" title="New">+</a>
  <form method="get" action="/go">
    {$octo}
    <div class="logo">cp</div>
    <div class="go">
      <input type="text" name="c" value="{$v}" placeholder="code" aria-label="Code" autocomplete="off" autocapitalize="off" spellcheck="false" autofocus required maxlength="48">
      <button type="submit" aria-label="Open">→</button>
    </div>
    {$err}
  </form>
</main>
HTML;
    return layout('cp', $body);
}

function message(string $title, string $text): string
{
    $p = $text === '' ? '' : '<p class="muted">' . h($text) . '</p>';
    $body = crumbs(null) . '<main class="center"><div class="card narrow"><h1>' . h($title) . '</h1>'
        . $p . '<p><a href="/">Back to start</a></p></div></main>';
    return layout($title . ' · cp', $body);
}

function editor(Note $note, bool $readonly, bool $adminLink): string
{
    $content = h($note->content);
    $ro = $readonly ? ' readonly' : '';
    // Share copies the note's canonical URL (never ?raw or other query strings).
    $actions = '<button type="button" data-share="' . h($note->path()) . '">Share</button>'
        . '<button type="button" data-copy="#content">Copy</button>'
        . '<a class="button" href="' . h($note->path()) . '?raw">Raw</a>';
    if (!$readonly) {
        $actions .= '<button type="button" class="danger" id="delete">Delete</button>';
    }
    // Both modes show status: read-only pages also live-update from the server.
    $status = '<span id="status" class="status"></span>';
    $settings = $adminLink ? '<a class="button" href="/new' . h($note->path()) . '">Settings</a>' : '';
    $body = crumbs($note, $status . '<span class="grow"></span>' . $actions . $settings) . <<<HTML
<main class="editor">
  <div id="conflict" class="banner warning" hidden>
    <span>Someone else saved this note. The text below is yours and is <strong>not</strong> on the server. Copy it, then reload.</span>
    <span class="row"><button type="button" data-copy="#content">Copy my text</button><button type="button" id="reload">Reload</button></span>
  </div>
  <div id="error" class="banner danger" hidden></div>
  <textarea id="content" spellcheck="false" autofocus{$ro}>{$content}</textarea>
  <div class="small muted"><span id="size"></span></div>
</main>
HTML;
    return layout($note->code . ' · cp', $body, [
        'page' => $readonly ? 'view' : 'editor',
        'hash' => $note->hash(),
        'url' => $note->path(),
        'max' => (string) MAX_BYTES,
    ]);
}

function unlock(Note $note, string $error = ''): string
{
    $err = $error === '' ? '' : '<p class="error">' . h($error) . '</p>';
    $action = h($note->path()) . '?a=unlock';
    $body = crumbs($note) . <<<HTML
<main class="center">
  <form class="card narrow" method="post" action="{$action}">
    <h1>This note is protected</h1>
    <label for="pw" class="muted">Password</label>
    <div class="row">
      <input id="pw" type="password" name="password" required autofocus autocomplete="current-password" class="grow">
      <button type="submit">Unlock</button>
    </div>
    {$err}
  </form>
</main>
HTML;
    return layout($note->code . ' · cp', $body);
}

function burnConfirm(Note $note): string
{
    $action = h($note->path()) . '?a=reveal';
    $body = crumbs($note) . <<<HTML
<main class="center">
  <form class="card narrow" method="post" action="{$action}">
    <h1>Burn after reading</h1>
    <p class="muted">This note is shown once and then deleted from the server. Copy what you need before leaving the page.</p>
    <button type="submit" class="danger">Show and destroy</button>
  </form>
</main>
HTML;
    return layout($note->code . ' · cp', $body);
}

function burnRevealed(Note $note): string
{
    $content = h($note->content);
    $body = crumbs($note, '<span class="status">Deleted from the server</span><span class="grow"></span><button type="button" data-copy="#content">Copy</button>') . <<<HTML
<main class="editor">
  <div class="banner warning"><span>This is the only copy left. It lives in this browser tab until you close it.</span></div>
  <textarea id="content" spellcheck="false" readonly>{$content}</textarea>
</main>
HTML;
    return layout($note->code . ' · cp', $body, ['page' => 'burned']);
}

/**
 * Shared settings fields for creation and editing.
 *
 * @param array<string, string> $v
 */
function settingsFields(array $v, bool $creating, bool $hasPassword): string
{
    $modes = '';
    $labels = ['edit' => 'Anyone with the link can edit', 'readonly' => 'Read-only (only you edit, from here)', 'burn' => 'Burn after reading'];
    foreach (MODES as $m) {
        $sel = ($v['mode'] ?? 'edit') === $m ? ' selected' : '';
        $modes .= '<option value="' . h($m) . '"' . $sel . '>' . h($labels[$m]) . '</option>';
    }
    $expiries = '';
    foreach (EXPIRY_OPTIONS as $key => $opt) {
        $sel = ($v['expiry'] ?? '') === $key ? ' selected' : '';
        $expiries .= '<option value="' . h($key) . '"' . $sel . '>' . h($opt['label']) . '</option>';
    }
    $expiryHint = $creating ? '' : '<p class="small muted">Saving restarts the countdown from now.</p>';
    if ($creating || !$hasPassword) {
        $pw = '<label for="password" class="muted">Password (optional)</label>'
            . '<input id="password" type="password" name="password" autocomplete="new-password">';
    } else {
        $pw = '<label for="password" class="muted">Password</label>'
            . '<select name="password_action" id="password_action"><option value="keep">Keep current password</option>'
            . '<option value="set">Change password</option><option value="clear">Remove password</option></select>'
            . '<input id="password" type="password" name="password" autocomplete="new-password" placeholder="New password">';
    }
    return <<<HTML
<label for="mode" class="muted">Mode</label>
<select id="mode" name="mode">{$modes}</select>
<label for="expiry" class="muted">Expires</label>
<select id="expiry" name="expiry">{$expiries}</select>
{$expiryHint}
{$pw}
HTML;
}

/**
 * @param list<array{zone: string, code: string, meta: array<string, mixed>, size: int}> $notes
 * @param array<string, string> $v
 */
function adminNew(array $notes, array $v, string $error, ?int $freeBytes): string
{
    $err = $error === '' ? '' : '<p class="error">' . h($error) . '</p>';
    $code = h($v['code'] ?? '');
    $content = h($v['content'] ?? '');
    $pub = ($v['zone'] ?? 'public') === 'public' ? ' checked' : '';
    $priv = ($v['zone'] ?? '') === 'private' ? ' checked' : '';
    $fields = settingsFields($v, true, false);
    $rows = '';
    $now = time();
    foreach ($notes as $n) {
        $path = ($n['zone'] === 'private' ? '/private/' : '/') . $n['code'];
        $flags = $n['meta']['mode'] . (\is_string($n['meta']['password'] ?? null) ? ', password' : '');
        $rows .= '<tr><td class="mono"><a href="/new' . h($path) . '">' . h($n['code']) . '</a></td><td>' . h($n['zone'])
            . '</td><td>' . h($flags) . '</td><td>' . h(humanBytes($n['size'])) . '</td><td>'
            . h(expiresIn($n['meta'], $now)) . '</td></tr>';
    }
    $list = $rows === '' ? '<p class="muted">No notes yet.</p>'
        : '<table><thead><tr><th>Code</th><th>Zone</th><th>Mode</th><th>Size</th><th>Expires</th></tr></thead><tbody>' . $rows . '</tbody></table>';
    $free = $freeBytes === null ? '' : '<p class="small muted">Free space: ' . h(humanBytes($freeBytes)) . '</p>';
    $body = crumbs(null) . <<<HTML
<main class="page">
  <form class="card" method="post" action="/new">
    <h1>New note</h1>
    <label for="code" class="muted">Code</label>
    <div class="row">
      <input id="code" type="text" name="code" value="{$code}" placeholder="random if empty" autocomplete="off" autocapitalize="off" spellcheck="false" maxlength="32" class="mono grow">
      <button type="button" id="random" aria-label="Random code">Random</button>
    </div>
    <p class="small muted">a–z, 0–9, _ and -, 3–32 characters</p>
    <span class="muted">Zone</span>
    <div class="row">
      <label><input type="radio" name="zone" value="public"{$pub}> Public</label>
      <label><input type="radio" name="zone" value="private"{$priv}> Private</label>
    </div>
    {$fields}
    <label for="content" class="muted">Initial content (required for burn after reading)</label>
    <textarea id="content" name="content" class="short" spellcheck="false">{$content}</textarea>
    {$err}
    <button type="submit" class="primary">Create note</button>
  </form>
  <section class="card">
    <h2>Notes</h2>
    {$list}
    {$free}
  </section>
</main>
HTML;
    return layout('New note · cp', $body, ['page' => 'new']);
}

function adminNote(Note $note, string $scheme, string $host, string $error, string $notice, ?string $content = null): string
{
    $err = $error === '' ? '' : '<p class="error">' . h($error) . '</p>';
    $ok = $notice === '' ? '' : '<p class="notice">' . h($notice) . '</p>';
    $share = h($scheme . '://' . $host . $note->path());
    $action = '/new' . h($note->path());
    $text = h($content ?? $note->content);
    $hash = h($note->hash());
    $fields = settingsFields([
        'mode' => $note->mode(),
        'expiry' => (string) ($note->meta['expiry'] ?? 'never'),
    ], false, $note->hasPassword());
    $open = $note->mode() === 'burn' ? '' : '<a class="button" href="' . h($note->path()) . '">Open</a>';
    $spoken = $note->zone === 'private' ? '<p class="small muted">Typed code: <span class="mono">priv/' . h($note->code) . '</span></p>' : '';
    $body = crumbs($note) . <<<HTML
<main class="page">
  <section class="card">
    <h1>Share</h1>
    <div class="row">
      <input id="share" type="text" value="{$share}" readonly class="mono grow">
      <button type="button" data-copy="#share">Copy link</button>
      {$open}
    </div>
    {$spoken}
    {$ok}
  </section>
  <form class="card" method="post" action="{$action}?a=save">
    <h2>Content and settings</h2>
    <input type="hidden" name="base" value="{$hash}">
    <textarea id="content" name="content" spellcheck="false">{$text}</textarea>
    {$fields}
    {$err}
    <button type="submit" class="primary">Save</button>
  </form>
  <form class="card" method="post" action="{$action}?a=delete" data-confirm="Delete this note for everyone?">
    <button type="submit" class="danger">Delete note</button>
  </form>
</main>
HTML;
    return layout('Settings ' . $note->code . ' · cp', $body, ['page' => 'admin']);
}

function humanBytes(int $bytes): string
{
    if ($bytes < 1024) {
        return $bytes . ' B';
    }
    if ($bytes < 1048576) {
        return round($bytes / 1024, 1) . ' KB';
    }
    return round($bytes / 1048576, 1) . ' MB';
}

/** @param array<string, mixed> $meta */
function expiresIn(array $meta, int $now): string
{
    $at = null;
    if (\is_int($meta['expires_at'] ?? null)) {
        $at = $meta['expires_at'];
    }
    if (\is_int($meta['idle'] ?? null)) {
        $idleAt = (int) $meta['updated_at'] + $meta['idle'];
        $at = $at === null ? $idleAt : min($at, $idleAt);
    }
    if ($at === null) {
        return 'never';
    }
    $left = max(0, $at - $now);
    return match (true) {
        $left < 3600 => (int) ceil($left / 60) . ' min',
        $left < 172800 => (int) round($left / 3600) . ' h',
        default => (int) round($left / 86400) . ' d',
    };
}
