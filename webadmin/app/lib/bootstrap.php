<?php
// ---------------------------------------------------------------------------
// LockdIn admin-panel - faelles opsaetning for alle sider
//
// Konfiguration (DB-login m.m.) ligger UDEN FOR web-roden i en JSON-fil, som
// webadmin.tf skriver paa VM'en. Lokalt kan stien saettes med LOCKDIN_CONFIG.
// ---------------------------------------------------------------------------

declare(strict_types=1);

const SESSION_IDLE_SECONDS = 30 * 60;
const MAX_FAILED_LOGINS = 5;
const LOGIN_LOCK_MINUTES = 15;
// Ansigtsbilleder: mindst 5 forskellige billeder giver en robust genkendelse
const MIN_FACE_IMAGES = 5;
const MAX_FACE_IMAGES = 20;
const MAX_FACE_IMAGE_BYTES = 10 * 1024 * 1024;

$configFile = getenv('LOCKDIN_CONFIG') ?: '/etc/lockdin-webadmin/config.json';
$config = json_decode((string) @file_get_contents($configFile), true);
if (!is_array($config)) {
    http_response_code(500);
    exit('Konfiguration mangler.');
}

date_default_timezone_set($config['timezone'] ?? 'Europe/Copenhagen');

// --- Session: kun over HTTPS, ikke tilgaengelig for JavaScript ---
session_name('lockdin_admin');
session_set_cookie_params([
    'lifetime' => 0,
    'path' => '/',
    'secure' => (bool) ($config['cookie_secure'] ?? true),
    'httponly' => true,
    'samesite' => 'Strict',
]);
ini_set('session.use_strict_mode', '1');
session_start();

if (isset($_SESSION['last_seen']) && time() - $_SESSION['last_seen'] > SESSION_IDLE_SECONDS) {
    $_SESSION = [];
    session_regenerate_id(true);
    $_SESSION['flash'] = ['warning', 'Logget ud.', 'Du var inaktiv i over 30 minutter.'];
}
$_SESSION['last_seen'] = time();

function db(): PDO
{
    global $config;
    static $pdo = null;
    if ($pdo === null) {
        $pdo = new PDO($config['db_dsn'], $config['db_user'], $config['db_password'], [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]);
    }
    return $pdo;
}

function q(string $sql, array $args = []): PDOStatement
{
    $st = db()->prepare($sql);
    $st->execute($args);
    return $st;
}

function h($s): string
{
    return htmlspecialchars((string) $s, ENT_QUOTES, 'UTF-8');
}

function redirect(string $to): void
{
    header('Location: ' . $to);
    exit;
}

/** Besked til naeste side: "<strong>Gemt.</strong> Profilen er opdateret." */
function flash(string $kind, string $title, string $text = ''): void
{
    $_SESSION['flash'] = [$kind, $title, $text];
}

// --- Login ---

function current_admin(): ?string
{
    return $_SESSION['admin'] ?? null;
}

function require_login(): string
{
    $admin = current_admin();
    if ($admin === null) {
        redirect('login.php');
    }
    return $admin;
}

// --- CSRF: alle POST-formularer skal have csrf_field() ---

function csrf_token(): string
{
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf'];
}

function csrf_field(): string
{
    return '<input type="hidden" name="csrf" value="' . h(csrf_token()) . '">';
}

function require_post(): void
{
    if ($_SERVER['REQUEST_METHOD'] !== 'POST'
        || !hash_equals(csrf_token(), (string) ($_POST['csrf'] ?? ''))) {
        http_response_code(400);
        exit('Ugyldig formular. Genindlaes siden og proev igen.');
    }
}

// --- Visning ---

function label(string $kind, string $text): string
{
    return '<span class="li-label li-label-' . h($kind) . '">' . h($text) . '</span>';
}

/** Status for en bruger-raekke: [label-type, tekst] */
function user_status(array $u): array
{
    $now = date('Y-m-d H:i:s');
    if (!$u['is_active']) return ['inactive', 'Inaktiv'];
    if ($u['locked_until'] && $u['locked_until'] > $now) return ['warning', 'Låst'];
    if ($u['valid_until'] && $u['valid_until'] <= $now) return ['denied', 'Udløbet'];
    if ($u['valid_from'] && $u['valid_from'] > $now) return ['default', 'Ikke startet'];
    if ($u['is_temporary']) return ['warning', 'Midlertidig'];
    return ['granted', 'Aktiv'];
}

const FACE_IMAGE_STATUS = [
    'pending' => ['default', 'Behandles'],
    'ok' => ['granted', 'Ansigt fundet'],
    'no_face' => ['denied', 'Intet ansigt'],
    'multiple_faces' => ['warning', 'Flere ansigter'],
    'error' => ['denied', 'Ulæseligt'],
];

/**
 * Gem uploadede ansigtsbilleder (<input type=file name=photos[] multiple>) i
 * upload-mappen og opret face_images-raekker. Alt eller intet: er et billede
 * ugyldigt, gemmes ingen. Returnerer antal gemte eller en fejltekst.
 */
function save_face_images(array $files, int $userId, string $admin): int|string
{
    global $config;
    $dir = $config['face_upload_dir'] ?? '/var/lib/lockdin-faces';

    // $_FILES['photos'] har et array pr. felt - vend det til et pr. fil
    $list = [];
    foreach ((array) ($files['error'] ?? []) as $i => $err) {
        if ($err === UPLOAD_ERR_NO_FILE) continue;
        $list[] = ['error' => $err, 'tmp' => $files['tmp_name'][$i], 'size' => $files['size'][$i],
                   'name' => $files['name'][$i]];
    }
    if (count($list) < MIN_FACE_IMAGES) return 'Vælg mindst ' . MIN_FACE_IMAGES . ' billeder (du valgte ' . count($list) . ').';
    if (count($list) > MAX_FACE_IMAGES) return 'Højst ' . MAX_FACE_IMAGES . ' billeder ad gangen.';

    $finfo = new finfo(FILEINFO_MIME_TYPE);
    $ext = ['image/jpeg' => 'jpg', 'image/png' => 'png'];
    foreach ($list as &$f) {
        if ($f['error'] === UPLOAD_ERR_INI_SIZE || $f['error'] === UPLOAD_ERR_FORM_SIZE
            || $f['size'] > MAX_FACE_IMAGE_BYTES) {
            return $f['name'] . ' er for stort (maks. ' . (MAX_FACE_IMAGE_BYTES >> 20) . ' MB).';
        }
        if ($f['error'] !== UPLOAD_ERR_OK || !is_uploaded_file($f['tmp'])) return 'Upload af ' . $f['name'] . ' fejlede.';
        // Indholdet afgoer typen - ikke filnavnet eller browserens Content-Type
        $mime = $finfo->file($f['tmp']);
        if (!isset($ext[$mime]) || @getimagesize($f['tmp']) === false) return $f['name'] . ' er ikke et JPEG- eller PNG-billede.';
        $f['ext'] = $ext[$mime];
    }
    unset($f);

    if (!is_dir($dir) || !is_writable($dir)) return 'Upload-mappen findes ikke på serveren.';
    $saved = [];
    db()->beginTransaction();
    try {
        foreach ($list as $f) {
            // Tilfaeldigt navn: brugerens filnavn kommer aldrig i naerheden af disken
            $name = bin2hex(random_bytes(16)) . '.' . $f['ext'];
            if (!move_uploaded_file($f['tmp'], "$dir/$name")) throw new RuntimeException('move_uploaded_file');
            chmod("$dir/$name", 0640);
            $saved[] = "$dir/$name";
            q('INSERT INTO face_images (user_id, file_name, uploaded_by) VALUES (?, ?, ?)', [$userId, $name, $admin]);
        }
        db()->commit();
    } catch (Throwable $e) {
        db()->rollBack();
        foreach ($saved as $path) @unlink($path);
        throw $e;
    }
    return count($saved);
}

function fmt_time(?string $ts, string $fmt = 'd-m H:i:s'): string
{
    return $ts ? date($fmt, strtotime($ts)) : '–';
}

const METHOD_NAMES = [
    'face_rfid' => 'RFID + ansigt',
    'rfid_pin' => 'RFID + PIN',
    'support' => 'Support',
    'unknown' => 'Ukendt',
];

/** "2026-11-23T14:00" fra <input type=datetime-local> -> DATETIME eller null */
function parse_local_datetime(string $s): ?string
{
    $s = trim($s);
    if ($s === '') return null;
    $d = DateTime::createFromFormat('Y-m-d\TH:i', $s);
    if (!$d) throw new InvalidArgumentException('Ugyldig dato: ' . $s);
    return $d->format('Y-m-d H:i:00');
}

function to_local_datetime(?string $ts): string
{
    return $ts ? date('Y-m-d\TH:i', strtotime($ts)) : '';
}

function page_header(string $title, ?string $active = null): void
{
    global $config;
    $admin = current_admin();
    $nav = ['profiler.php' => 'Profiler', 'doere.php' => 'Døre',
            'adgangslog.php' => 'Adgangslog', 'support.php' => 'Support'];
    ?>
<!doctype html>
<html lang="da">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= h($title) ?> – LockdIn</title>
<link rel="stylesheet" href="assets/lockdin.css">
<script src="assets/app.js"></script>
</head>
<body>
<?php if ($admin !== null): ?>
<nav class="li-navbar"><div class="li-container">
<a class="li-brand" href="profiler.php"><img src="assets/img/lockdin-mark-white.png" alt="" width="31" height="34">LockdIn</a>
<ul class="li-nav">
<?php foreach ($nav as $href => $name): ?>
  <li<?= $active === $name ? ' class="active"' : '' ?>><a href="<?= $href ?>"><?= $name ?></a></li>
<?php endforeach; ?>
</ul>
<div class="li-navbar-right">Logget ind som <b><?= h($admin) ?></b>
  <form method="post" action="logout.php" class="li-inline"><?= csrf_field() ?><button class="li-link">Log ud</button></form></div>
</div></nav>
<?php endif; ?>
<div class="li-container">
<?php
    if (!empty($_SESSION['flash'])) {
        [$kind, $title, $text] = $_SESSION['flash'];
        unset($_SESSION['flash']);
        $cls = ['success' => 'success', 'warning' => 'warning', 'danger' => 'danger'][$kind] ?? 'warning';
        echo '<div class="li-alert li-alert-' . $cls . ' li-flash"><strong>' . h($title) . '</strong> ' . h($text) . '</div>';
    }
}

function page_footer(): void
{
    global $config;
    ?>
<div class="li-footer">LockdIn adgangskontrol · <?= h($config['site_name'] ?? 'Filial') ?> ·
  <a href="#" data-toggle-theme>Skift lyst/mørkt</a></div>
</div>
</body>
</html>
<?php
}
