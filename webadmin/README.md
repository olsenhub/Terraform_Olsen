# LockdIn admin-panel

Web-panelet, hvor kundens IT-team administrerer adgangskontrollen. Det er
skrevet i PHP uden framework, med design fra LockdIn-design-systemet
(https://claude.ai/artifact/TkQbSza8DxsDG1D8YLmBWv), og rulles ud af
[`webadmin.tf`](../webadmin.tf).

| Mappe | Indhold |
|---|---|
| `app/public/` | Siderne. Kun denne mappe serveres af Apache. |
| `app/lib/bootstrap.php` | Fælles kode: DB, session, login, CSRF, layout |
| `mockups/` | De oprindelige statiske mockups |

## Sider

| Side | Funktion |
|---|---|
| `login.php` | Login. Kontoen låses i 15 min efter 5 forkerte forsøg. |
| `profiler.php` | Alle brugere med søgning og filtre (rolle, status) |
| `profil.php` | Opret og redigér: navn, rolle, kort-UID, PIN, gyldighed, fravalg af ansigt. Spær kort, lås op, deaktivér, tilmeld eller slet ansigt. |
| `doere.php` | Døre med online-status (heartbeat), adgang pr. rolle, tilføj dør, tag ud af drift |
| `adgangslog.php` | Alle adgangsforsøg med filtre, sideskift og CSV-eksport |
| `support.php` | Fjernåbning med begrundelse og udstedelse af midlertidigt kort (Gæst, kort + PIN) |

Panelet taler ikke selv med dørene. Det skriver i databasen, og
[adgangs-servicen](../services/access_service/README.md) gør resten:
- Ændringer af brugere og rettigheder gælder fra næste kortlæsning.
- Fjernåbning og tilmelding af ansigt indsættes i `door_commands`. Servicen
  sender dem til døren inden for et sekund.

## Sikkerhed

1. **Netværk:** Port 8443 er kun åben i NSG'en for `customer_admin_ips` og
   vores egne admin-IP'er. Apache har samme liste (`Require ip`).
2. **TLS:** Panelet bruger samme certifikat som MQTT-brokeren, signeret af
   vores egen CA. Importér `mqtt-ca.crt` (`terraform output mqtt_ca_download`)
   som betroet CA i browseren for at undgå advarslen.
3. **Login:** Passwords gemmes med bcrypt (`password_hash`). Session-cookien
   er `Secure`, `HttpOnly` og `SameSite=Strict`. Sessionen udløber efter 30
   minutters inaktivitet, og der logges ud med POST.
4. **Formularer:** Alle POST'er kræver et CSRF-token. Al SQL bruger prepared
   statements, og alt output escapes med `h()`.
5. **Headers:** Content-Security-Policy (kun egne scripts),
   `X-Frame-Options: DENY` og `nosniff`.
6. **Sporbarhed:** Fjernåbninger logges i `access_log` med admin-brugernavn og
   begrundelse. Mislykkede logins skrives i Apaches fejllog.
7. **Hemmeligheder:** DB-login ligger i `/etc/lockdin-webadmin/config.json`
   uden for web-roden og kan kun læses af root og www-data.

**Kendte begrænsninger:**
- Der er kun én admin-rolle, og der er ingen side til at oprette flere
  admins. Den første konto kommer fra `terraform.tfvars`.
- Live-kamera på supportsiden kommer med Pi-integrationen.
- Panelet bruger samme DB-bruger som adgangs-servicen (`access_app`).

## Lokal udvikling

Det kræver PHP 8.1+ med `pdo_mysql` og `mbstring` samt en MariaDB med
skemaet fra `database.tf`:

```bash
cat > /tmp/lockdin.json <<'EOF'
{"db_dsn": "mysql:host=127.0.0.1;dbname=adgangskontrol;charset=utf8mb4",
 "db_user": "access_app", "db_password": "...", "site_name": "Lokal",
 "cookie_secure": false}
EOF
LOCKDIN_CONFIG=/tmp/lockdin.json php -S 127.0.0.1:8080 -t webadmin/app/public
```

## Efter `terraform apply`

```bash
terraform output webadmin_url          # https://<ip>:8443
```

Log ind med `webadmin_admin_username` / `webadmin_admin_password` fra
`terraform.tfvars`. Fejl kan ses på VM'en med:

```bash
sudo tail -f /var/log/apache2/lockdin-admin-error.log
```
