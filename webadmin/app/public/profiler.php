<?php
require __DIR__ . '/../lib/bootstrap.php';
require_login();

$search = trim((string) ($_GET['q'] ?? ''));
$roleId = (int) ($_GET['role'] ?? 0);
$status = (string) ($_GET['status'] ?? '');

$roles = q('SELECT id, name FROM roles ORDER BY id')->fetchAll();

$where = [];
$args = [];
if ($search !== '') {
    $where[] = '(u.name LIKE ? OR u.card_uid LIKE ?)';
    $args[] = "%$search%";
    $args[] = "%$search%";
}
if ($roleId) {
    $where[] = 'u.role_id = ?';
    $args[] = $roleId;
}
$users = q('SELECT u.*, r.name AS role_name,
              (SELECT COUNT(*) FROM user_faces f WHERE f.user_id = u.id) AS faces
            FROM users u JOIN roles r ON r.id = u.role_id'
           . ($where ? ' WHERE ' . implode(' AND ', $where) : '')
           . ' ORDER BY u.is_active DESC, u.name', $args)->fetchAll();

// Status regnes i PHP (samme regler som adgangs-servicen), derfor filtreres her
$statusNames = ['granted' => 'Aktiv', 'warning' => 'Låst/midlertidig', 'denied' => 'Udløbet', 'inactive' => 'Inaktiv'];
if (isset($statusNames[$status])) {
    $users = array_values(array_filter($users, fn($u) => user_status($u)[0] === $status));
}

$counts = q('SELECT SUM(is_active) AS active, SUM(NOT is_active) AS inactive FROM users')->fetch();

page_header('Profiler', 'Profiler');
?>
<div class="li-page-header">
  <h1>Profiler <small><?= (int) $counts['active'] ?> aktive · <?= (int) $counts['inactive'] ?> inaktive</small></h1>
  <div class="li-actions"><a class="li-btn" href="support.php#midlertidigt">Udsted midlertidigt kort</a>
    <a class="li-btn li-btn-primary" href="profil.php">+ Ny profil</a></div>
</div>

<div class="li-panel"><form class="li-panel-body li-toolbar" method="get">
  <div class="li-form-group" style="flex:2"><label for="q">Søg</label>
    <input id="q" name="q" class="li-input" placeholder="Navn eller kort-UID" value="<?= h($search) ?>"></div>
  <div class="li-form-group" style="flex:1"><label for="r">Rolle</label>
    <select id="r" name="role" class="li-select"><option value="0">Alle roller</option>
    <?php foreach ($roles as $r): ?><option value="<?= $r['id'] ?>"<?= $roleId === (int) $r['id'] ? ' selected' : '' ?>><?= h($r['name']) ?></option><?php endforeach; ?>
    </select></div>
  <div class="li-form-group" style="flex:1"><label for="s">Status</label>
    <select id="s" name="status" class="li-select"><option value="">Alle</option>
    <?php foreach ($statusNames as $k => $n): ?><option value="<?= $k ?>"<?= $status === $k ? ' selected' : '' ?>><?= $n ?></option><?php endforeach; ?>
    </select></div>
  <button class="li-btn">Filtrér</button>
</form></div>

<div class="li-panel">
<table class="li-table li-table-striped">
<thead><tr><th>Navn</th><th>Rolle</th><th>Kort-UID</th><th class="li-check-cell">PIN sat</th><th class="li-check-cell">Ansigt</th><th>Status</th><th></th></tr></thead>
<tbody>
<?php foreach ($users as $u): [$kind, $text] = user_status($u); ?>
<tr>
  <td><a href="profil.php?id=<?= $u['id'] ?>"><?= h($u['name']) ?></a></td>
  <td><?= label('default', $u['role_name']) ?></td>
  <td><code><?= h($u['card_uid'] ?? '–') ?></code></td>
  <td class="li-check-cell"><?= $u['pin_hash'] ? 'Ja' : '<span class="li-muted">Nej</span>' ?></td>
  <td class="li-check-cell"><?= $u['face_opt_out'] ? '<span class="li-muted">Fravalgt</span>' : ($u['faces'] ? 'Ja' : '<span class="li-muted">Nej</span>') ?></td>
  <td><?= label($kind, $text) ?>
    <?php if ($kind === 'warning' && $u['is_temporary'] && $u['valid_until']): ?><small class="li-muted">til <?= fmt_time($u['valid_until'], 'd-m H:i') ?></small><?php endif; ?></td>
  <td style="text-align:right"><a class="li-btn li-btn-sm" href="profil.php?id=<?= $u['id'] ?>">Redigér</a></td>
</tr>
<?php endforeach; ?>
<?php if (!$users): ?><tr><td colspan="7" class="li-muted">Ingen profiler matcher filteret.</td></tr><?php endif; ?>
</tbody></table>
<div class="li-panel-footer">Viser <?= count($users) ?> profiler</div>
</div>
<?php page_footer();
