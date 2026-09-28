<?php

declare(strict_types=1);

// Test harness only: emulates the nginx routing in deploy/nginx/cp.conf for
// `php -S`, so the app can be exercised without php-fpm. Not deployed.

$uri = (string) parse_url((string) $_SERVER['REQUEST_URI'], PHP_URL_PATH);
$root = dirname(__DIR__) . '/app';
// Emit exactly the add_header lines of the real nginx config: browser behaviour
// (CSP, and Referrer-Policy's effect on the Origin header) must match production.
$nginxConf = (string) file_get_contents(dirname(__DIR__) . '/deploy/nginx/cp.conf');
preg_match_all('/^\s*add_header\s+(\S+)\s+"([^"]*)"/m', $nginxConf, $headers, PREG_SET_ORDER);
foreach ($headers as [, $name, $value]) {
    header($name . ': ' . $value);
}

if (str_starts_with($uri, '/static/')) {
    $file = realpath($root . '/public' . $uri);
    if ($file === false || !str_starts_with($file, $root . '/public/static/')) {
        http_response_code(404);
        return true;
    }
    return false; // let php -S serve it
}

$routes = [
    ['#^/$#', 'home', null, false],
    ['#^/go$#', 'go', null, false],
    ['#^/new$#', 'new', null, true],
    ['#^/new/([a-z0-9_-]{3,32})$#', 'admin', 'public', true],
    ['#^/new/private/([a-z0-9_-]{3,32})$#', 'admin', 'private', true],
    ['#^/private/([a-z0-9_-]{3,32})$#', 'note', 'private', true],
    ['#^/([a-z0-9_-]{3,32})$#', 'note', 'public', false],
];
foreach ($routes as [$re, $route, $zone, $auth]) {
    if (preg_match($re, $uri, $m) === 1) {
        $_SERVER['CP_ROUTE'] = $route;
        if ($zone !== null) {
            $_SERVER['CP_ZONE'] = $zone;
            $_SERVER['CP_CODE'] = $m[1];
        }
        if ($auth) {
            $_SERVER['REMOTE_USER'] = 'tester'; // nginx auth_basic already passed
        } elseif (isset($_SERVER['HTTP_AUTHORIZATION'])) {
            // Like nginx: on locations without auth_basic, REMOTE_USER is whatever
            // user an Authorization header claims (unchecked).
            $_SERVER['REMOTE_USER'] = 'spoofed';
        }
        // Tests may inject raw params to check PHP-side validation.
        foreach (['CP_ROUTE', 'CP_ZONE', 'CP_CODE'] as $k) {
            $h = 'HTTP_X_TEST_' . $k;
            if (isset($_SERVER[$h])) {
                $_SERVER[$k] = $_SERVER[$h];
            }
        }
        require $root . '/src/front.php';
        return true;
    }
}
http_response_code(404);
return true;
