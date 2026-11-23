<?php
require __DIR__ . '/../lib/bootstrap.php';
require_login();

$roles = q('SELECT id, name FROM roles ORDER BY id')->fetchAll();
$errors = [];
$new = ['name' => '', 'location' => '', 'device_id' => ''];

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    require_post();
    $action = $_POST['action'] ?? '';

    if ($action === 'save_matrix') {
        // Hele rolle/doer-matrixen gemmes paa en gang i en transaktion
        $pdo = db();
        $pdo->beginTransaction();
        $pdo->exec('DELETE FROM role_door_access');
        $ins = $pdo->prepare('INSERT INTO role_door_access (role_id, door_id) VALUES (?, ?)');
        foreach ((array) ($_POST['access'] ?? []) as $roleId => $doorIds) {
            foreach ((array) $doorIds as $doorId => $on) {
                $ins->execute([(int) $roleId, (int) $doorId]);
            }
        }
        $pdo->commit();
        flash('success', 'Gemt.', 'Adgang pr. rolle gælder med det samme.');
        redirect('doere.php');
    }

    if ($action === 'toggle') {
        q('UPDATE doors SET is_active = NOT is_active WHERE id = ?', [(int) ($_POST['door_id'] ?? 0)]);
        flash('success', 'Dørens status er ændret.');
        redirect('doere.php');
    }

    if ($action === 'add') {
        $new = [
            'name' => trim((string) ($_POST['name'] ?? '')),
            'location' => trim((string) ($_POST['location'] ?? '')),
            'device_id' => strtolower(trim((string) ($_POST['device_id'] ?? ''))),
        ];
        if ($new['name'] === '' || mb_strlen($new['name']) > 100) $errors['name'] = 'Navn skal udfyldes.';
        // device_id indgaar i MQTT-emnet, saa ingen / + # eller mellemrum
        if (!preg_match('/^[a-z0-9][a-z0-9-]{2,63}$/', $new['device_id'])) $errors['device_id'] = 'Kun a-z, 0-9 og -, fx door-serverrum.';
        if (!$errors) {
            try {
                q('INSERT INTO doors (name, location, device_id, is_active) VALUES (?, ?, ?, TRUE)',
                  [$new['name'], $new['location'] ?: null, $new['device_id']]);
                flash('success', 'Dør tilføjet.', 'Giv ' . $new['name'] . ' adgang pr. rolle nedenfor og konfigurér Pi\'en med device-ID ' . $new['device_id'] . '.');
                redirect('doere.php');
            } catch (PDOException $e) {
                if (($e->errorInfo[1] ?? 0) !== 1062) throw $e;
                $errors['device_id'] = 'Navn eller device-ID findes allerede.';
            }
        }
    }
}

$doors = q('SELECT * FROM doors ORDER BY id')->fetchAll();
$access = [];
foreach (q('SELECT role_id, door_id FROM role_door_access')->fetchAll() as $a) {
    $access[$a['role_id']][$a['door_id']] = true;
}
$active = count(array_filter($doors, fn($d) => $d['is_active']));
$offline = array_filter($doors, fn($d) => $d['is_active'] && !$d['is_online'] && $d['last_seen']);

function door_status(array $d): string
{
    if (!$d['is_active']) return '<span class="li-muted">Ikke i drift</span>';
    if (!$d['last_seen']) return '<span class="li-muted">Aldrig set</span>';
    return $d['is_online'] ? '<span class="li-dot li-dot-online"></span>Online' : '<span class="li-dot li-dot-offline"></span>Offline';
}

page_header('Døre', 'Døre');
?>
<div class="li-page-header">
  <h1>Døre <small><?= $active ?> i drift · <?= count($doors) - $active ?> ikke i drift</small></h1>
  <div class="li-actions"><a class="li-btn li-btn-primary" href="#ny-doer">+ Tilføj dør</a></div>
</div>

<?php foreach ($offline as $d): ?>
<div class="li-alert li-alert-danger"><strong>Dør offline.</strong> <?= h($d['name']) ?> har ikke været forbundet siden <?= fmt_time($d['last_seen'], 'd-m H:i') ?>. Tjek strøm og netværk på enheden.</div>
<?php endforeach; ?>

<div class="li-panel"><div class="li-panel-heading"><h3 class="li-panel-title">Enheder</h3></div>
<table class="li-table li-table-striped">
<thead><tr><th>Dør</th><th>Device-ID</th><th>Status</th><th>Sidst set</th><th></th></tr></thead>
<tbody>
<?php foreach ($doors as $d): ?>
<tr>
  <td><b><?= h($d['name']) ?></b><br><span class="li-help li-help-tight"><?= h($d['location'] ?? '') ?></span></td>
  <td><code><?= h($d['device_id']) ?></code></td>
  <td><?= door_status($d) ?></td>
  <td><code><?= fmt_time($d['last_seen'], 'd-m H:i:s') ?></code></td>
  <td style="text-align:right">
    <?php if ($d['is_active']): ?><a class="li-btn li-btn-sm" href="support.php?door=<?= $d['id'] ?>">Åbn dør</a><?php endif; ?>
    <form method="post" class="li-inline"><?= csrf_field() ?><input type="hidden" name="action" value="toggle"><input type="hidden" name="door_id" value="<?= $d['id'] ?>">
      <button class="li-btn li-btn-sm"<?= $d['is_active'] ? ' data-confirm="Tag ' . h($d['name']) . ' ud af drift? Døren afviser så alle."' : '' ?>><?= $d['is_active'] ? 'Tag ud af drift' : 'Sæt i drift' ?></button></form>
  </td>
</tr>
<?php endforeach; ?>
</tbody></table></div>

<form class="li-panel" method="post"><?= csrf_field() ?><input type="hidden" name="action" value="save_matrix">
<div class="li-panel-heading"><h3 class="li-panel-title">Adgang pr. rolle</h3>
  <div class="li-actions"><button class="li-btn li-btn-sm li-btn-primary">Gem ændringer</button></div></div>
<table class="li-table li-table-striped">
<thead><tr><th>Dør</th><?php foreach ($roles as $r): ?><th class="li-check-cell"><?= h($r['name']) ?></th><?php endforeach; ?></tr></thead>
<tbody>
<?php foreach ($doors as $d): ?>
<tr><td><?= h($d['name']) ?></td>
  <?php foreach ($roles as $r): ?>
  <td class="li-check-cell"><input type="checkbox" name="access[<?= $r['id'] ?>][<?= $d['id'] ?>]" value="1"
      aria-label="<?= h($r['name'] . ' – ' . $d['name']) ?>"<?= isset($access[$r['id']][$d['id']]) ? ' checked' : '' ?>></td>
  <?php endforeach; ?>
</tr>
<?php endforeach; ?>
</tbody></table>
<div class="li-panel-footer">Ændringer gælder med det samme for alle brugere med rollen.</div>
</form>

<div class="li-panel" id="ny-doer"><div class="li-panel-heading"><h3 class="li-panel-title">Tilføj dør</h3></div>
<form class="li-panel-body" method="post"><?= csrf_field() ?><input type="hidden" name="action" value="add">
  <div class="li-row">
    <div class="li-form-group<?= isset($errors['name']) ? ' li-has-error' : '' ?>"><label for="dn">Navn</label>
      <input id="dn" name="name" class="li-input" value="<?= h($new['name']) ?>" placeholder="Serverrum">
      <?= isset($errors['name']) ? '<span class="li-help">' . h($errors['name']) . '</span>' : '' ?></div>
    <div class="li-form-group"><label for="dl">Placering</label>
      <input id="dl" name="location" class="li-input" value="<?= h($new['location']) ?>" placeholder="Kælder"></div>
    <div class="li-form-group<?= isset($errors['device_id']) ? ' li-has-error' : '' ?>"><label for="dd">Device-ID</label>
      <input id="dd" name="device_id" class="li-input li-mono" value="<?= h($new['device_id']) ?>" placeholder="door-serverrum">
      <span class="li-help"><?= h($errors['device_id'] ?? 'Bruges i MQTT-emnet iot/door/<device-ID>/…') ?></span></div>
  </div>
  <button class="li-btn li-btn-primary">Tilføj dør</button>
</form></div>
<?php page_footer();
