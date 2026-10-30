<?php
/*
 * TMDB proxy for the 5heures app: holds the TMDB token on the server, so the app (and its public
 * source code) never contains it.
 *
 * Only what the app needs is passed through:
 *   tmdb.php?path=search/movie&query=Coward&language=fr-FR&year=2026
 *   tmdb.php?path=movie/123456&language=fr-FR&append_to_response=credits
 * Answers are cached on disk for 30 days, and each visitor is limited to 120 requests a minute.
 *
 * The token lives in tmdb-config.php (not in the repo), looked for next to this file's folder first
 * (outside the web root, if the hosting allows), then next to this file:
 *   <?php return ['token' => 'eyJ…'];
 */

header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');

function fail(int $status, string $message): void {
    http_response_code($status);
    echo json_encode(['error' => $message]);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'GET') fail(405, 'GET only');

// ---- the token ----------------------------------------------------------------------------------
$config = null;
foreach ([dirname(__DIR__) . '/tmdb-config.php', __DIR__ . '/tmdb-config.php'] as $file) {
    if (is_file($file)) { $config = include $file; break; }
}
$token = is_array($config) ? ($config['token'] ?? '') : '';
if ($token === '') fail(500, 'proxy not configured');

// ---- what may be asked --------------------------------------------------------------------------
$path = $_GET['path'] ?? '';
if (!preg_match('#^(search/movie|movie/\d{1,9}(/credits)?)$#', $path)) fail(400, 'path not allowed');

$allowed = ['query', 'language', 'year', 'primary_release_year', 'page', 'include_adult', 'append_to_response', 'region'];
$params = [];
foreach ($allowed as $name) {
    if (isset($_GET[$name]) && is_string($_GET[$name]) && strlen($_GET[$name]) <= 200) $params[$name] = $_GET[$name];
}
if (isset($params['append_to_response']) && $params['append_to_response'] !== 'credits') fail(400, 'append not allowed');
ksort($params);

// ---- folders for the cache and the rate limit ---------------------------------------------------
$base = sys_get_temp_dir() . '/cinqheures-tmdb';
@mkdir($base . '/cache', 0700, true);
@mkdir($base . '/rate', 0700, true);

// ---- rate limit: 120 requests a minute per address ----------------------------------------------
$ip = $_SERVER['REMOTE_ADDR'] ?? 'unknown';
$rateFile = $base . '/rate/' . hash('sha256', $ip . '|' . gmdate('YmdHi'));
$count = (int) @file_get_contents($rateFile);
if ($count >= 120) fail(429, 'too many requests, try again in a minute');
@file_put_contents($rateFile, (string) ($count + 1), LOCK_EX);
if (mt_rand(1, 200) === 1) {                       // now and then, drop old counters
    foreach (glob($base . '/rate/*') ?: [] as $old) if (filemtime($old) < time() - 300) @unlink($old);
}

// ---- cache: 30 days -----------------------------------------------------------------------------
$url = 'https://api.themoviedb.org/3/' . $path . ($params ? '?' . http_build_query($params) : '');
$cacheFile = $base . '/cache/' . hash('sha256', $url) . '.json';
if (is_file($cacheFile) && filemtime($cacheFile) > time() - 30 * 86400) {
    header('X-Cache: HIT');
    readfile($cacheFile);
    exit;
}

// ---- ask TMDB -----------------------------------------------------------------------------------
$curl = curl_init($url);
curl_setopt_array($curl, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT => 15,
    CURLOPT_HTTPHEADER => ['Authorization: Bearer ' . $token, 'Accept: application/json'],
]);
$body = curl_exec($curl);
$status = (int) curl_getinfo($curl, CURLINFO_HTTP_CODE);
curl_close($curl);

if ($body === false || $status === 0) fail(502, 'TMDB unreachable');
http_response_code($status);
if ($status === 200) @file_put_contents($cacheFile, $body, LOCK_EX);
header('X-Cache: MISS');
echo $body;
