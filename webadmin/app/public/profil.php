<?php
require __DIR__ . '/../lib/bootstrap.php';
$admin = require_login();

$id = (int) ($_GET['id'] ?? 0);
$roles = q('SELECT id, name FROM roles ORDER BY id')->fetchAll();

function load_user(int $id): ?array
{
    $u = q('SELECT u.*, r.name AS role_name FROM users u JOIN roles r ON r.id = u.role_id
            WHERE u.id = ?', [$id])->fetch();
    return $u ?: null;
}

$user = $id ? load_user($id) : null;
if ($id && !$user) {
    http_response_code(404);
    exit('Profilen findes ikke.');
}

$errors = [];
// Formularens vaerdier: fra POST ved fejl, ellers fra databasen
$form = [
    'name' => $user['name'] ?? '',
    'role_id' => (int) ($user['role_id'] ?? 0),
    'card_uid' => $user['card_uid'] ?? '',
    'valid_from' => to_local_datetime($user['valid_from'] ?? null),
    'valid_until' => to_local_datetime($user['valid_until'] ?? null),
    'face_opt_out' => (bool) ($user['face_opt_out'] ?? false),
];

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    require_post();
    $action = $_POST['action'] ?? 'save';

    if ($action === 'save') {
        $form = [
            'name' => trim((string) ($_POST['name'] ?? '')),
            'role_id' => (int) ($_POST['role_id'] ?? 0),
            'card_uid' => strtoupper(trim((string) ($_POST['card_uid'] ?? ''))),
            'valid_from' => (string) ($_POST['valid_from'] ?? ''),
            'valid_until' => (string) ($_POST['valid_until'] ?? ''),
            'face_opt_out' => !empty($_POST['face_opt_out']),
        ];
        $pin = trim((string) ($_POST['pin'] ?? ''));

        if ($form['name'] === '' || mb_strlen($form['name']) > 100) $errors['name'] = 'Navn skal udfyldes (maks. 100 tegn).';
        if (!in_array($form['role_id'], array_map('intval', array_column($roles, 'id')), true)) $errors['role_id'] = 'Vælg en rolle.';
        if ($form['card_uid'] !== '' && !preg_match('/^[0-9A-Z:-]{4,64}$/', $form['card_uid'])) $errors['card_uid'] = 'Kort-UID må kun indeholde 0-9, A-Z, : og -.';
        if ($pin !== '' && !preg_match('/^\d{4,6}$/', $pin)) $errors['pin'] = 'PIN skal være 4–6 cifre.';
        try {
            $from = parse_local_datetime($form['valid_from']);
            $until = parse_local_datetime($form['valid_until']);
            if ($from && $until && $until <= $from) $errors['valid_until'] = '"Gyldig til" skal være efter "Gyldig fra".';
        } catch (InvalidArgumentException $e) {
            $errors['valid_until'] = 'Ugyldig dato.';
        }

        if (!$errors) {
            $data = [$form['name'], $form['role_id'], $form['card_uid'] ?: null,
                     (int) $form['face_opt_out'], $from, $until];
            try {
                if ($user) {
                    q('UPDATE users SET name = ?, role_id = ?, card_uid = ?, face_opt_out = ?,
                         valid_from = ?, valid_until = ? WHERE id = ?', [...$data, $user['id']]);
                    $id = (int) $user['id'];
                } else {
                    q('INSERT INTO users (name, role_id, card_uid, face_opt_out, valid_from, valid_until)
                       VALUES (?, ?, ?, ?, ?, ?)', $data);
                    $id = (int) db()->lastInsertId();
                }
                if ($pin !== '') {
                    // Samme bcrypt som adgangs-servicen tjekker. Ny PIN laaser op.
                    q('UPDATE users SET pin_hash = ?, failed_pin_attempts = 0, locked_until = NULL
                       WHERE id = ?', [password_hash($pin, PASSWORD_BCRYPT), $id]);
                }
                flash('success', 'Gemt.', 'Profilen for ' . $form['name'] . ' er ' . ($user ? 'opdateret.' : 'oprettet.'));
                redirect('profil.php?id=' . $id);
            } catch (PDOException $e) {
                if (($e->errorInfo[1] ?? 0) !== 1062) throw $e;   // 1062 = dubleret noegle
                $owner = q('SELECT name FROM users WHERE card_uid = ?', [$form['card_uid']])->fetchColumn();
                $errors['card_uid'] = 'Kortet er allerede tildelt ' . $owner . '.';
            }
        }
    } elseif ($user) {
        $uid = (int) $user['id'];
        switch ($action) {
            case 'deactivate':
                q('UPDATE users SET is_active = FALSE WHERE id = ?', [$uid]);
                flash('success', 'Bruger deaktiveret.', 'Adgangsloggen bevares.');
                break;
            case 'activate':
                q('UPDATE users SET is_active = TRUE WHERE id = ?', [$uid]);
                flash('success', 'Bruger aktiveret.');
                break;
            case 'unlock':
                q('UPDATE users SET failed_pin_attempts = 0, locked_until = NULL WHERE id = ?', [$uid]);
                flash('success', 'Låst op.', 'Forkerte PIN-forsøg er nulstillet.');
                break;
            case 'block_card':
                q('UPDATE users SET card_uid = NULL WHERE id = ?', [$uid]);
                flash('warning', 'Kort spærret.', 'Profilen har intet kort, før et nyt tildeles.');
                break;
            case 'clear_pin':
                q('UPDATE users SET pin_hash = NULL WHERE id = ?', [$uid]);
                flash('success', 'PIN fjernet.');
                break;
            case 'delete_faces':
                q('DELETE FROM user_faces WHERE user_id = ?', [$uid]);
                flash('success', 'Ansigtsdata slettet.');
                break;
            case 'enroll_face':
                $doorId = (int) ($_POST['door_id'] ?? 0);
                $door = q('SELECT name FROM doors WHERE id = ? AND is_active', [$doorId])->fetchColumn();
                if ($door === false) {
                    flash('danger', 'Ukendt dør.');
                    break;
                }
                q('INSERT INTO door_commands (door_id, action, user_id, requested_by) VALUES (?, ?, ?, ?)',
                  [$doorId, 'enroll_face', $uid, $admin]);
                flash('success', 'Tilmelding sendt til ' . $door . '.',
                      $user['name'] . ' skal stå foran kameraet. Genindlæs siden bagefter.');
                break;
        }
        redirect('profil.php?id=' . $uid);
    }
}

$faces = $user ? q('SELECT COUNT(*) AS n, MAX(created_at) AS last FROM user_faces WHERE user_id = ?', [$user['id']])->fetch() : null;
$doors = q('SELECT id, name, device_id FROM doors WHERE is_active ORDER BY id')->fetchAll();
$doorAccess = q('SELECT r.id AS role_id, GROUP_CONCAT(d.name ORDER BY d.id SEPARATOR ", ") AS doors
                 FROM roles r LEFT JOIN role_door_access a ON a.role_id = r.id
                 LEFT JOIN doors d ON d.id = a.door_id GROUP BY r.id')->fetchAll(PDO::FETCH_KEY_PAIR);
$attempts = $user ? q('SELECT l.*, d.name AS door FROM access_log l JOIN doors d ON d.id = l.door_id
                       WHERE l.user_id = ? ORDER BY l.id DESC LIMIT 8', [$user['id']])->fetchAll() : [];

function err(array $errors, string $field): string
{
    return isset($errors[$field]) ? '<span class="li-help">' . h($errors[$field]) . '</span>' : '';
}
function errcls(array $errors, string $field): string
{
    return isset($errors[$field]) ? ' li-has-error' : '';
}

page_header($user ? $user['name'] : 'Ny profil', 'Profiler');
?>
<div class="li-page-header">
  <h1><?= $user ? h($user['name']) . ' <small>' . h($user['role_name']) . '</small>' : 'Ny profil' ?></h1>
  <div class="li-actions"><a class="li-btn" href="profiler.php">&larr; Tilbage</a></div>
</div>

<?php if ($errors): ?><div class="li-alert li-alert-danger"><strong>Ikke gemt.</strong> Ret felterne markeret med rødt.</div><?php endif; ?>

<div class="li-grid">
<div>
 <div class="li-panel"><div class="li-panel-heading"><h3 class="li-panel-title">Stamdata</h3></div>
 <form class="li-panel-body" method="post" action="profil.php<?= $user ? '?id=' . $user['id'] : '' ?>">
  <?= csrf_field() ?><input type="hidden" name="action" value="save">
  <div class="li-row">
   <div class="li-form-group<?= errcls($errors, 'name') ?>"><label for="n">Navn</label>
     <input id="n" name="name" class="li-input" value="<?= h($form['name']) ?>" maxlength="100" required><?= err($errors, 'name') ?></div>
   <div class="li-form-group<?= errcls($errors, 'role_id') ?>"><label for="r">Rolle</label>
     <select id="r" name="role_id" class="li-select" data-role-doors>
     <?php if (!$form['role_id']): ?><option value="">Vælg rolle …</option><?php endif; ?>
     <?php foreach ($roles as $r): ?>
       <option value="<?= $r['id'] ?>" data-doors="<?= h($doorAccess[$r['id']] ?? 'ingen døre') ?>"<?= $form['role_id'] === (int) $r['id'] ? ' selected' : '' ?>><?= h($r['name']) ?></option>
     <?php endforeach; ?></select>
     <span class="li-help" data-role-doors-help><?= $form['role_id'] ? 'Adgang: ' . h($doorAccess[$form['role_id']] ?? 'ingen døre') : '' ?></span><?= err($errors, 'role_id') ?></div>
  </div>
  <div class="li-row">
   <div class="li-form-group<?= errcls($errors, 'card_uid') ?>"><label for="c">Kort-UID</label>
     <input id="c" name="card_uid" class="li-input li-mono" value="<?= h($form['card_uid']) ?>" placeholder="04:A3:2F:1B">
     <?= err($errors, 'card_uid') ?: '<span class="li-help">Scan kortet på en læser eller skriv UID\'et.</span>' ?></div>
   <div class="li-form-group<?= errcls($errors, 'pin') ?>"><label for="p"><?= $user && $user['pin_hash'] ? 'Ny PIN' : 'PIN' ?></label>
     <input id="p" name="pin" class="li-input" type="password" inputmode="numeric" autocomplete="new-password" placeholder="<?= $user && $user['pin_hash'] ? 'Uændret' : '4–6 cifre' ?>">
     <?= err($errors, 'pin') ?: '<span class="li-help">4–6 cifre. Vises aldrig igen efter gem.</span>' ?></div>
  </div>
  <div class="li-row">
   <div class="li-form-group"><label for="vf">Gyldig fra</label>
     <input id="vf" name="valid_from" type="datetime-local" class="li-input" value="<?= h($form['valid_from']) ?>"></div>
   <div class="li-form-group<?= errcls($errors, 'valid_until') ?>"><label for="vt">Gyldig til</label>
     <input id="vt" name="valid_until" type="datetime-local" class="li-input" value="<?= h($form['valid_until']) ?>">
     <?= err($errors, 'valid_until') ?: '<span class="li-help">Tom = ingen udløb.</span>' ?></div>
  </div>
  <div class="li-form-group"><label class="li-check"><input type="checkbox" name="face_opt_out" value="1"<?= $form['face_opt_out'] ? ' checked' : '' ?>> Fravælg ansigtsgenkendelse (bruger kort + PIN)</label></div>
  <button class="li-btn li-btn-primary"><?= $user ? 'Gem profil' : 'Opret profil' ?></button>
  <a class="li-btn" href="profiler.php">Annullér</a>
 </form></div>

 <?php if ($user): ?>
 <div class="li-panel"><div class="li-panel-heading"><h3 class="li-panel-title">Seneste adgangsforsøg</h3>
   <div class="li-actions"><a href="adgangslog.php?user=<?= $user['id'] ?>">Hele loggen &rarr;</a></div></div>
 <table class="li-table li-table-striped"><thead><tr><th>Tid</th><th>Dør</th><th>Metode</th><th>Resultat</th><th>Årsag</th></tr></thead><tbody>
 <?php foreach ($attempts as $a): ?>
  <tr><td><code><?= fmt_time($a['timestamp']) ?></code></td><td><?= h($a['door']) ?></td><td><?= h(METHOD_NAMES[$a['method']] ?? $a['method']) ?></td>
    <td><?= $a['granted'] ? label('granted', 'Godkendt') : label('denied', 'Afvist') ?></td>
    <td><?= $a['reason'] ? '<code>' . h($a['reason']) . '</code>' : '<span class="li-muted">–</span>' ?></td></tr>
 <?php endforeach; ?>
 <?php if (!$attempts): ?><tr><td colspan="5" class="li-muted">Ingen forsøg endnu.</td></tr><?php endif; ?>
 </tbody></table></div>
 <?php endif; ?>
</div>

<?php if ($user): [$kind, $text] = user_status($user); ?>
<div>
 <div class="li-panel"><div class="li-panel-heading"><h3 class="li-panel-title">Ansigtsgenkendelse</h3></div><div class="li-panel-body">
  <?php if ($user['face_opt_out']): ?>
    <p class="li-muted" style="margin:0">Fravalgt – brugeren åbner med kort + PIN.</p>
  <?php else: ?>
    <p style="margin:0 0 10px"><?= $faces['n'] ? label('granted', 'Tilmeldt') . ' ' . (int) $faces['n'] . ' billede(r) · ' . fmt_time($faces['last'], 'd-m-Y') : label('default', 'Ikke tilmeldt') ?></p>
    <form method="post"><?= csrf_field() ?><input type="hidden" name="action" value="enroll_face">
      <div class="li-form-group"><label for="d">Tilmeld via dør</label>
        <select id="d" name="door_id" class="li-select"><?php foreach ($doors as $d): ?><option value="<?= $d['id'] ?>"><?= h($d['name']) ?> (<?= h($d['device_id']) ?>)</option><?php endforeach; ?></select>
        <span class="li-help">Personen stiller sig foran kameraet. Kun embeddings gemmes, ikke billeder.</span></div>
      <button class="li-btn"><?= $faces['n'] ? 'Tilføj ansigt' : 'Tilmeld ansigt' ?></button>
    </form>
    <?php if ($faces['n']): ?>
    <form method="post" style="margin-top:10px"><?= csrf_field() ?><input type="hidden" name="action" value="delete_faces">
      <button class="li-btn li-btn-sm li-btn-danger" data-confirm="Slet alle ansigtsdata for <?= h($user['name']) ?>?">Slet ansigtsdata</button></form>
    <?php endif; ?>
  <?php endif; ?>
 </div></div>

 <div class="li-panel"><div class="li-panel-heading"><h3 class="li-panel-title">Status</h3></div><div class="li-panel-body">
  <dl class="li-dl">
   <dt>Status</dt><dd><?= label($kind, $text) ?></dd>
   <dt>Forkerte PIN</dt><dd><?= (int) $user['failed_pin_attempts'] ?></dd>
   <?php if ($user['locked_until']): ?><dt>Låst til</dt><dd><code><?= fmt_time($user['locked_until'], 'd-m H:i') ?></code></dd><?php endif; ?>
   <dt>Oprettet</dt><dd><code><?= fmt_time($user['created_at'], 'd-m-Y') ?></code></dd>
  </dl>
 </div>
 <div class="li-panel-footer li-actions-row">
  <?php
  $buttons = [];
  if ($user['locked_until'] || $user['failed_pin_attempts']) $buttons[] = ['unlock', 'Lås op', '', ''];
  if ($user['card_uid']) $buttons[] = ['block_card', 'Spær kort', 'li-btn-danger', 'Spær kortet ' . $user['card_uid'] . '?'];
  if ($user['pin_hash']) $buttons[] = ['clear_pin', 'Fjern PIN', '', 'Fjern PIN for ' . $user['name'] . '?'];
  $buttons[] = $user['is_active']
      ? ['deactivate', 'Deaktivér bruger', 'li-btn-danger', 'Deaktivér ' . $user['name'] . '? Loggen bevares.']
      : ['activate', 'Aktivér bruger', '', ''];
  foreach ($buttons as [$act, $txt, $cls, $confirm]): ?>
   <form method="post" class="li-inline"><?= csrf_field() ?><input type="hidden" name="action" value="<?= $act ?>">
    <button class="li-btn li-btn-sm <?= $cls ?>"<?= $confirm ? ' data-confirm="' . h($confirm) . '"' : '' ?>><?= $txt ?></button></form>
  <?php endforeach; ?>
  <span class="li-help">Deaktivering bevarer loggen.</span>
 </div></div>
</div>
<?php endif; ?>
</div>
<?php page_footer();
