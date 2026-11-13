<?php
// Stores a personal integration_openai API key (encrypted by the app) for the users in
// KEYS_JSON={"uid":"key",...}. Run via: docker exec -i -u www-data --env-file F <nc> php < this
// (see provision-assistant-user-key.sh). Never prints a key.
require_once '/var/www/html/lib/base.php';
$svc = \OC::$server->get(\OCA\OpenAi\Service\OpenAiSettingsService::class);
$users = \OC::$server->get(\OCP\IUserManager::class);
$keys = json_decode(getenv('KEYS_JSON') ?: '{}', true);
$bad = 0;
foreach ($keys as $uid => $key) {
    if (!$users->userExists($uid)) { echo "SKIP $uid: no such user\n"; $bad++; continue; }
    $svc->setUserApiKey($uid, $key);
    $ok = $svc->getUserApiKey($uid, false) === $key;
    echo ($ok ? "OK   " : "FAIL ") . "$uid\n";
    if (!$ok) { $bad++; }
}
exit($bad ? 1 : 0);
