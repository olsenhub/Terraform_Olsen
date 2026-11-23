<?php
require __DIR__ . '/../lib/bootstrap.php';

if (current_admin() !== null) {
    redirect('profiler.php');
}

$error = null;
$username = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    require_post();
    $username = trim((string) ($_POST['username'] ?? ''));
    $password = (string) ($_POST['password'] ?? '');

    $a = q('SELECT id, username, password_hash, failed_logins, locked_until
            FROM admin_users WHERE username = ?', [$username])->fetch();

    if ($a && $a['locked_until'] && strtotime($a['locked_until']) > time()) {
        $error = 'Kontoen er låst efter for mange forkerte forsøg. Prøv igen om ' . LOGIN_LOCK_MINUTES . ' minutter.';
    } else {
        // Ukendt bruger tjekkes mod en dummy-hash, saa svartiden ikke afsloerer
        // hvilke brugernavne der findes
        $hash = $a['password_hash'] ?? password_hash('dummy', PASSWORD_BCRYPT);
        if (password_verify($password, $hash) && $a) {
            q('UPDATE admin_users SET failed_logins = 0, locked_until = NULL, last_login = NOW()
               WHERE id = ?', [$a['id']]);
            session_regenerate_id(true);
            $_SESSION['admin'] = $a['username'];
            $_SESSION['csrf'] = bin2hex(random_bytes(32));
            redirect('profiler.php');
        }
        if ($a) {
            q('UPDATE admin_users SET failed_logins = failed_logins + 1,
                 locked_until = IF(failed_logins >= ?, NOW() + INTERVAL ? MINUTE, NULL)
               WHERE id = ?', [MAX_FAILED_LOGINS, LOGIN_LOCK_MINUTES, $a['id']]);
        }
        error_log('LockdIn admin: mislykket login for "' . $username . '" fra ' . ($_SERVER['REMOTE_ADDR'] ?? '?'));
        $error = 'Forkert brugernavn eller adgangskode.';
    }
}

page_header('Log ind');
?>
<div class="li-login">
<div class="li-panel">
  <div class="li-login-head"><img src="assets/img/lockdin-logo-white.png" alt="LockdIn" width="150"></div>
  <div class="li-panel-body">
    <?php if ($error): ?><div class="li-alert li-alert-danger"><strong>Kunne ikke logge ind.</strong> <?= h($error) ?></div><?php endif; ?>
    <form method="post" action="login.php">
      <?= csrf_field() ?>
      <div class="li-form-group"><label for="u">Brugernavn</label>
        <input id="u" name="username" class="li-input" value="<?= h($username) ?>" autocomplete="username" required autofocus></div>
      <div class="li-form-group"><label for="p">Adgangskode</label>
        <input id="p" name="password" class="li-input" type="password" autocomplete="current-password" required></div>
      <button class="li-btn li-btn-primary li-btn-block">Log ind</button>
    </form>
  </div>
  <div class="li-panel-footer">Kun tilgængelig fra kundens whitelistede IP-adresser. Alle logins logges.</div>
</div></div>
<?php page_footer();
