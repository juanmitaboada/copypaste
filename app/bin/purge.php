<?php

declare(strict_types=1);

// Deletes expired notes. Run by cp-purge.timer as the cp user; access-time
// expiry in the web app covers the gap between runs.

namespace Cp;

require \dirname(__DIR__) . '/src/lib.php';

if (PHP_SAPI !== 'cli') {
    exit(1);
}

$config = Config::fromEnvironment();
try {
    $purged = (new Store($config->dataDir))->purgeExpired(time());
} catch (\RuntimeException $e) {
    // Non-zero exit makes the systemd unit (and audit.sh) report the failure.
    fwrite(STDERR, 'cp-purge: ' . $e->getMessage() . "\n");
    exit(1);
}
fwrite(STDOUT, "cp-purge: removed {$purged} expired note(s)\n");
