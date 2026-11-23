<?php
require __DIR__ . '/../lib/bootstrap.php';

redirect(current_admin() === null ? 'login.php' : 'profiler.php');
