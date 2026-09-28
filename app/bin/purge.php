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
$purged = (new Store($config->dataDir))->purgeExpired(time());
fwrite(STDOUT, "cp-purge: removed {$purged} expired note(s)\n");
