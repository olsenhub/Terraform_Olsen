<?php
require __DIR__ . '/../lib/bootstrap.php';

require_post();
$_SESSION = [];
session_regenerate_id(true);
flash('success', 'Logget ud.');
redirect('login.php');
