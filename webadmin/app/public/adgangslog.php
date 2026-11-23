<?php
require __DIR__ . '/../lib/bootstrap.php';
require_login();

const PER_PAGE = 50;

$today = date('Y-m-d');
$f = [
    'from' => (string) ($_GET['from'] ?? $today),
    'to' => (string) ($_GET['to'] ?? $today),
    'door' => (int) ($_GET['door'] ?? 0),
    'method' => (string) ($_GET['method'] ?? ''),
    'result' => (string) ($_GET['result'] ?? ''),
    'user' => (int) ($_GET['user'] ?? 0),
];
foreach (['from', 'to'] as $k) {
    if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $f[$k])) $f[$k] = $today;
}

$where = ['l.`timestamp` >= DATE(?)', 'l.`timestamp` < DATE(?) + INTERVAL 1 DAY'];
$args = [$f['from'], $f['to']];
if ($f['door']) { $where[] = 'l.door_id = ?'; $args[] = $f['door']; }
if (isset(METHOD_NAMES[$f['method']])) { $where[] = 'l.method = ?'; $args[] = $f['method']; }
if ($f['result'] === 'granted') $where[] = 'l.granted';
if ($f['result'] === 'denied') $where[] = 'NOT l.granted';
if ($f['user']) { $where[] = 'l.user_id = ?'; $args[] = $f['user']; }
$whereSql = ' WHERE ' . implode(' AND ', $where);

$from = ' FROM access_log l JOIN doors d ON d.id = l.door_id LEFT JOIN users u ON u.id = l.user_id';
$select = 'SELECT l.*, d.name AS door, u.name AS user_name' . $from . $whereSql . ' ORDER BY l.id DESC';

// --- CSV-eksport af hele filteret ---
if (($_GET['export'] ?? '') === 'csv') {
    header('Content-Type: text/csv; charset=utf-8');
    header('Content-Disposition: attachment; filename="adgangslog_' . $f['from'] . '_' . $f['to'] . '.csv"');
    $out = fopen('php://output', 'w');
    fwrite($out, "\xEF\xBB\xBF");   // BOM, saa Excel laeser ae/oe/aa rigtigt
    fputcsv($out, ['tid', 'doer', 'bruger', 'kort_uid', 'metode', 'resultat', 'aarsag', 'support', 'note', 'svartid_ms'], ';');
    $st = q($select, $args);
    while ($r = $st->fetch()) {
        fputcsv($out, [$r['timestamp'], $r['door'], $r['user_name'], $r['card_uid'], $r['method'],
                       $r['granted'] ? 'godkendt' : 'afvist', $r['reason'], $r['support_operator'],
                       $r['note'], $r['response_ms']], ';');
    }
    exit;
}

$total = (int) q('SELECT COUNT(*)' . $from . $whereSql, $args)->fetchColumn();
$pages = max(1, (int) ceil($total / PER_PAGE));
$page = min($pages, max(1, (int) ($_GET['page'] ?? 1)));
$rows = q($select . ' LIMIT ' . PER_PAGE . ' OFFSET ' . (($page - 1) * PER_PAGE), $args)->fetchAll();

$stats = q('SELECT COUNT(*) AS n, SUM(NOT granted) AS denied, ROUND(AVG(response_ms)) AS avg_ms
            FROM access_log WHERE `timestamp` >= CURDATE()')->fetch();
$doors = q('SELECT id, name FROM doors ORDER BY id')->fetchAll();
$filterUser = $f['user'] ? q('SELECT name FROM users WHERE id = ?', [$f['user']])->fetchColumn() : null;

function page_url(array $f, array $extra): string
{
    return 'adgangslog.php?' . http_build_query(array_filter(array_merge($f, $extra)));
}

page_header('Adgangslog', 'Adgangslog');
?>
<div class="li-page-header">
  <h1>Adgangslog <small>i dag: <?= (int) $stats['n'] ?> forsøg · <?= (int) $stats['denied'] ?> afvist<?= $stats['avg_ms'] !== null ? ' · gns. svartid ' . (int) $stats['avg_ms'] . ' ms' : '' ?></small></h1>
  <div class="li-actions"><a class="li-btn" href="<?= h(page_url($f, ['export' => 'csv'])) ?>">Eksportér CSV</a></div>
</div>

<div class="li-panel"><form class="li-panel-body li-toolbar" method="get">
  <?php if ($f['user']): ?><input type="hidden" name="user" value="<?= $f['user'] ?>"><?php endif; ?>
  <div class="li-form-group"><label for="f">Fra</label><input id="f" name="from" type="date" class="li-input" value="<?= h($f['from']) ?>"></div>
  <div class="li-form-group"><label for="t">Til</label><input id="t" name="to" type="date" class="li-input" value="<?= h($f['to']) ?>"></div>
  <div class="li-form-group"><label for="d">Dør</label><select id="d" name="door" class="li-select"><option value="0">Alle døre</option>
    <?php foreach ($doors as $d): ?><option value="<?= $d['id'] ?>"<?= $f['door'] === (int) $d['id'] ? ' selected' : '' ?>><?= h($d['name']) ?></option><?php endforeach; ?></select></div>
  <div class="li-form-group"><label for="m">Metode</label><select id="m" name="method" class="li-select"><option value="">Alle</option>
    <?php foreach (METHOD_NAMES as $k => $n): ?><option value="<?= $k ?>"<?= $f['method'] === $k ? ' selected' : '' ?>><?= $n ?></option><?php endforeach; ?></select></div>
  <div class="li-form-group"><label for="g">Resultat</label><select id="g" name="result" class="li-select">
    <option value="">Alle</option><option value="granted"<?= $f['result'] === 'granted' ? ' selected' : '' ?>>Godkendt</option><option value="denied"<?= $f['result'] === 'denied' ? ' selected' : '' ?>>Afvist</option></select></div>
  <button class="li-btn li-btn-primary">Filtrér</button>
</form></div>

<?php if ($filterUser !== null): ?>
<p>Viser kun <b><?= h($filterUser ?: 'slettet bruger') ?></b> · <a href="<?= h(page_url(array_merge($f, ['user' => 0]), [])) ?>">vis alle brugere</a></p>
<?php endif; ?>

<div class="li-panel">
<table class="li-table li-table-striped">
<thead><tr><th>Tid</th><th>Dør</th><th>Bruger</th><th>Metode</th><th>Resultat</th><th>Årsag</th><th class="li-num">Svartid</th></tr></thead>
<tbody>
<?php foreach ($rows as $r): ?>
<tr>
  <td><code><?= fmt_time($r['timestamp']) ?></code></td>
  <td><?= h($r['door']) ?></td>
  <td><?php if ($r['user_id']): ?><a href="profil.php?id=<?= $r['user_id'] ?>"><?= h($r['user_name']) ?></a>
      <?php elseif ($r['card_uid']): ?><span class="li-muted">Ukendt kort</span> <code><?= h($r['card_uid']) ?></code>
      <?php else: ?><span class="li-muted">–</span><?php endif; ?></td>
  <td><?= h(METHOD_NAMES[$r['method']] ?? $r['method']) ?></td>
  <td><?= $r['granted'] ? label('granted', 'Godkendt') : label('denied', 'Afvist') ?></td>
  <td><?php if ($r['method'] === 'support'): ?>åbnet af <?= h($r['support_operator']) ?><?= $r['note'] ? '<br><span class="li-help li-help-tight">' . h($r['note']) . '</span>' : '' ?>
      <?php elseif ($r['reason']): ?><code><?= h($r['reason']) ?></code>
      <?php else: ?><span class="li-muted">–</span><?php endif; ?></td>
  <td class="li-num"><?= $r['response_ms'] !== null ? (int) $r['response_ms'] . ' ms' : '–' ?></td>
</tr>
<?php endforeach; ?>
<?php if (!$rows): ?><tr><td colspan="7" class="li-muted">Ingen adgangsforsøg i perioden.</td></tr><?php endif; ?>
</tbody></table>
<div class="li-panel-footer li-actions-row">
  Viser <?= $total ? (($page - 1) * PER_PAGE + 1) . '–' . (($page - 1) * PER_PAGE + count($rows)) : 0 ?> af <?= $total ?>
  <?php if ($pages > 1): ?>
  <ul class="li-pagination" style="margin-left:auto">
    <?php if ($page > 1): ?><li><a href="<?= h(page_url($f, ['page' => $page - 1])) ?>">&laquo;</a></li><?php endif; ?>
    <?php for ($p = max(1, $page - 3); $p <= min($pages, $page + 3); $p++): ?>
      <li<?= $p === $page ? ' class="active"' : '' ?>><?= $p === $page ? "<span>$p</span>" : '<a href="' . h(page_url($f, ['page' => $p])) . '">' . $p . '</a>' ?></li>
    <?php endfor; ?>
    <?php if ($page < $pages): ?><li><a href="<?= h(page_url($f, ['page' => $page + 1])) ?>">&raquo;</a></li><?php endif; ?>
  </ul>
  <?php endif; ?>
</div>
</div>
<?php page_footer();
