// LockdIn admin-panel. Indlaeses i <head>, saa temaet er sat foer siden tegnes.
// Ingen inline-scripts: Content-Security-Policy tillader kun filer herfra.
(function () {
  var KEY = 'lockdin-theme';
  var root = document.documentElement;
  try {
    var saved = localStorage.getItem(KEY);
    if (saved) root.setAttribute('data-theme', saved);
  } catch (e) { /* privat vindue o.l. - lyst tema */ }

  document.addEventListener('click', function (ev) {
    // Lyst/moerkt tema
    var toggle = ev.target.closest('[data-toggle-theme]');
    if (toggle) {
      ev.preventDefault();
      var next = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      try { localStorage.setItem(KEY, next); } catch (e) {}
      return;
    }
    // Bekraeftelse paa farlige knapper: <button data-confirm="...">
    var btn = ev.target.closest('[data-confirm]');
    if (btn && !window.confirm(btn.getAttribute('data-confirm'))) {
      ev.preventDefault();
    }
  });

  // Profil: vis hvilke doere den valgte rolle giver adgang til
  document.addEventListener('change', function (ev) {
    if (!ev.target.matches('[data-role-doors]')) return;
    var opt = ev.target.selectedOptions[0];
    var help = ev.target.parentNode.querySelector('[data-role-doors-help]');
    if (help) help.textContent = opt && opt.dataset.doors ? 'Adgang: ' + opt.dataset.doors : '';
  });
})();
