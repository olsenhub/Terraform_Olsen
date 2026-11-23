<?php
require __DIR__ . '/../lib/bootstrap.php';
$admin = require_login();

$doors = q('SELECT id, name, device_id, is_online FROM doors WHERE is_active ORDER BY id')->fetchAll();
$users = q('SELECT id, name FROM users WHERE is_active ORDER BY name')->fetchAll();
$guestRole = q("SELECT id FROM roles WHERE name = 'Gaest'")->fetchColumn();

$errors = [];
$open = ['door_id' => (int) ($_GET['door'] ?? ($doors[0]['id'] ?? 0)), 'user_id' => 0, 'reason' => ''];
$temp = ['name' => '', 'card_uid' => '', 'hours' => '8'];
$hourChoices = ['2' => '2 timer', '8' => '8 timer (resten af dagen)', '24' => '24 timer', '72' => '3 dage'];

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    require_post();
    $action = $_POST['action'] ?? '';

    if ($action === 'open') {
        $open = ['door_id' => (int) ($_POST['door_id'] ?? 0), 'user_id' => (int) ($_POST['user_id'] ?? 0),
                 'reason' => trim((string) ($_POST['reason'] ?? ''))];
        $door = q('SELECT name FROM doors WHERE id = ? AND is_active', [$open['door_id']])->fetchColumn();
        if ($door === false) $errors['door_id'] = 'Vælg en dør.';
        if ($open['reason'] === '' || mb_strlen($open['reason']) > 255) $errors['reason'] = 'Skriv en begrundelse (maks. 255 tegn) – den gemmes i loggen.';
        if (!$errors) {
            q('INSERT INTO door_commands (door_id, action, user_id, requested_by, reason) VALUES (?, ?, ?, ?, ?)',
              [$open['door_id'], 'open', $open['user_id'] ?: null, $admin, $open['reason']]);
            flash('success', $door . ' åbnes.', 'Kommandoen er sendt, og åbningen er logget med dit brugernavn.');
            redirect('support.php?door=' . $open['door_id']);
        }
    }

    if ($action === 'temp_card') {
        $temp = ['name' => trim((string) ($_POST['name'] ?? '')),
                 'card_uid' => strtoupper(trim((string) ($_POST['card_uid'] ?? ''))),
                 'hours' => (string) ($_POST['hours'] ?? '8')];
        if ($temp['name'] === '' || mb_strlen($temp['name']) > 100) $errors['name'] = 'Skriv navn eller firma.';
        if (!preg_match('/^[0-9A-Z:-]{4,64}$/', $temp['card_uid'])) $errors['card_uid'] = 'Kort-UID må kun indeholde 0-9, A-Z, : og -.';
        $pin = trim((string) ($_POST['pin'] ?? ''));
        if (!preg_match('/^\d{4,6}$/', $pin)) $errors['pin'] = 'PIN skal være 4–6 cifre.';
        if (!isset($hourChoices[$temp['hours']])) $errors['hours'] = 'Vælg en gyldighed.';
        if ($guestRole === false) $errors['name'] = 'Rollen "Gaest" findes ikke i databasen.';
        if (!$errors) {
            try {
                // Gaester har intet ansigt tilmeldt -> kort + PIN
                q('INSERT INTO users (name, role_id, card_uid, pin_hash, is_temporary, valid_from, valid_until, face_opt_out)
                   VALUES (?, ?, ?, ?, TRUE, NOW(), NOW() + INTERVAL ? HOUR, TRUE)',
                  [$temp['name'], $guestRole, $temp['card_uid'], password_hash($pin, PASSWORD_BCRYPT), (int) $temp['hours']]);
                flash('success', 'Midlertidigt kort udstedt.',
                      $temp['card_uid'] . ' til ' . $temp['name'] . ' gælder i ' . $hourChoices[$temp['hours']] . ' med kort + PIN (rollen Gæst).');
                redirect('profil.php?id=' . db()->lastInsertId());
            } catch (PDOException $e) {
                if (($e->errorInfo[1] ?? 0) !== 1062) throw $e;
                $errors['card_uid'] = 'Kortet er allerede tildelt en anden profil.';
            }
        }
    }
}

$pending = q('SELECT c.*, d.name AS door FROM door_commands c JOIN doors d ON d.id = c.door_id
              WHERE c.processed_at IS NULL ORDER BY c.id')->fetchAll();
$recent = q("SELECT l.*, d.name AS door, u.name AS user_name FROM access_log l
             JOIN doors d ON d.id = l.door_id LEFT JOIN users u ON u.id = l.user_id
             WHERE l.method = 'support' ORDER BY l.id DESC LIMIT 8")->fetchAll();
$selected = null;
foreach ($doors as $d) if ((int) $d['id'] === $open['door_id']) $selected = $d;

function field_error(array $errors, string $k): string
{
    return isset($errors[$k]) ? '<span class="li-help">' . h($errors[$k]) . '</span>' : '';
}
function has_error(array $errors, string $k): string
{
    return isset($errors[$k]) ? ' li-has-error' : '';
}

page_header('Support', 'Support');
?>
<div class="li-page-header"><h1>Fjernsupport <small>glemt kort / gæster</small></h1></div>

<?php if ($pending): ?>
<div class="li-alert li-alert-warning"><strong><?= count($pending) ?> kommando(er) venter.</strong>
  Adgangs-servicen har ikke sendt dem endnu – kører <code>lockdin-access</code> på serveren?</div>
<?php endif; ?>

<div class="li-grid">
<div>
 <div class="li-panel"><div class="li-panel-heading"><h3 class="li-panel-title">Kamera: <?= h($selected['name'] ?? '–') ?></h3>
   <div class="li-actions"><?= $selected && $selected['is_online'] ? '<span class="li-dot li-dot-online"></span>Online' : '<span class="li-dot li-dot-offline"></span>Offline' ?></div></div>
 <div class="li-panel-body"><div class="li-cam"><span class="rec"><?= h($selected['device_id'] ?? '') ?></span>Live-kamera kommer med Pi-integrationen</div></div></div>

 <div class="li-panel"><div class="li-panel-heading"><h3 class="li-panel-title">Seneste support-åbninger</h3></div>
 <table class="li-table li-table-striped"><thead><tr><th>Tid</th><th>Dør</th><th>Person</th><th>Åbnet af</th><th>Begrundelse</th></tr></thead><tbody>
 <?php foreach ($recent as $r): ?>
  <tr><td><code><?= fmt_time($r['timestamp']) ?></code></td><td><?= h($r['door']) ?></td>
    <td><?= $r['user_name'] ? h($r['user_name']) : '<span class="li-muted">Ekstern</span>' ?></td>
    <td><?= h($r['support_operator']) ?></td><td><?= h($r['note'] ?? '') ?></td></tr>
 <?php endforeach; ?>
 <?php if (!$recent): ?><tr><td colspan="5" class="li-muted">Ingen support-åbninger endnu.</td></tr><?php endif; ?>
 </tbody></table></div>
</div>

<div>
 <div class="li-panel"><div class="li-panel-heading"><h3 class="li-panel-title">Åbn dør</h3></div>
 <form class="li-panel-body" method="post"><?= csrf_field() ?><input type="hidden" name="action" value="open">
  <div class="li-form-group<?= has_error($errors, 'door_id') ?>"><label for="od">Dør</label>
    <select id="od" name="door_id" class="li-select"><?php foreach ($doors as $d): ?><option value="<?= $d['id'] ?>"<?= $open['door_id'] === (int) $d['id'] ? ' selected' : '' ?>><?= h($d['name']) ?></option><?php endforeach; ?></select>
    <?= field_error($errors, 'door_id') ?></div>
  <div class="li-form-group"><label for="ou">Hvem er det?</label>
    <select id="ou" name="user_id" class="li-select"><option value="0">Ekstern / gæst</option>
    <?php foreach ($users as $u): ?><option value="<?= $u['id'] ?>"<?= $open['user_id'] === (int) $u['id'] ? ' selected' : '' ?>><?= h($u['name']) ?></option><?php endforeach; ?></select></div>
  <div class="li-form-group<?= has_error($errors, 'reason') ?>"><label for="or">Begrundelse</label>
    <input id="or" name="reason" class="li-input" maxlength="255" value="<?= h($open['reason']) ?>" placeholder="Glemt kort, genkendt på kamera">
    <?= field_error($errors, 'reason') ?: '<span class="li-help">Gemmes i adgangsloggen sammen med dit brugernavn.</span>' ?></div>
  <button class="li-btn li-btn-primary" data-confirm="Åbn døren én gang nu?">Åbn dør én gang</button>
 </form></div>

 <div class="li-panel" id="midlertidigt"><div class="li-panel-heading"><h3 class="li-panel-title">Midlertidigt kort</h3></div>
 <form class="li-panel-body" method="post"><?= csrf_field() ?><input type="hidden" name="action" value="temp_card">
  <div class="li-form-group<?= has_error($errors, 'name') ?>"><label for="tn">Navn / firma</label>
    <input id="tn" name="name" class="li-input" value="<?= h($temp['name']) ?>" placeholder="VVS Jensen ApS"><?= field_error($errors, 'name') ?></div>
  <div class="li-form-group<?= has_error($errors, 'card_uid') ?>"><label for="tc">Kort-UID</label>
    <input id="tc" name="card_uid" class="li-input li-mono" value="<?= h($temp['card_uid']) ?>" placeholder="T-005"><?= field_error($errors, 'card_uid') ?></div>
  <div class="li-form-group<?= has_error($errors, 'pin') ?>"><label for="tp">PIN</label>
    <input id="tp" name="pin" class="li-input" type="password" inputmode="numeric" autocomplete="new-password" placeholder="4–6 cifre">
    <?= field_error($errors, 'pin') ?: '<span class="li-help">Gives til gæsten sammen med kortet.</span>' ?></div>
  <div class="li-form-group<?= has_error($errors, 'hours') ?>"><label for="th">Gyldigt i</label>
    <select id="th" name="hours" class="li-select"><?php foreach ($hourChoices as $k => $n): ?><option value="<?= $k ?>"<?= $temp['hours'] === (string) $k ? ' selected' : '' ?>><?= $n ?></option><?php endforeach; ?></select>
    <span class="li-help">Giver rollen "Gæst": kun de døre, Gæst har adgang til.</span></div>
  <button class="li-btn">Udsted kort</button>
 </form></div>
</div>
</div>
<?php page_footer();
