# LockdIn adgangs-service

Python-daemon på VM'en, der forbinder dør-enhederne (Raspberry Pi) med
adgangskontrol-databasen. Den rulles ud af [`access_service.tf`](../../access_service.tf)
og kører som systemd-servicen `lockdin-access`.

```
Pi (RFID + kamera/numpad)                VM
  ── MQTT/TLS 8883 ──▶  Mosquitto  ──1883 lokal──▶  lockdin-access  ──▶  MariaDB
  ◀── åbn / afvis ────                           ◀──                   (users, doors,
                                                                        access_log …)
```

## Flow for en adgangsanmodning

1. Pi'en læser kortet og tager et ansigt (eller PIN) og publicerer på
   `iot/door/<device_id>/request`.
2. Servicen slår kortet op i `users`, tjekker konto (aktiv, gyldig periode,
   ikke låst), derefter **legitimation** (ansigt eller PIN) og til sidst
   **rettighed** via `v_current_access`.
3. Forsøget skrives i `access_log` med metode, resultat, årsag og `response_ms`.
4. Svaret sendes på `iot/door/<device_id>/response`.

Legitimationen tjekkes før rettigheden, så et afvist forsøg ikke afslører, om
et kort har adgang til en dør, før kortholderen har bevist sin identitet.

## MQTT-emner og beskeder

| Emne | Retning | Indhold |
|---|---|---|
| `iot/door/<id>/request` | Pi → service | `{"request_id", "card_uid", "method": "face_rfid", "image": "<base64 JPEG>"}` eller `{"…", "method": "rfid_pin", "pin": "1234"}` |
| `iot/door/<id>/response` | service → Pi | `{"request_id", "granted", "reason", "user", "open_seconds"}` |
| `iot/door/<id>/status` | Pi → service | `{"online": true}` (retained). Sæt LWT til `{"online": false}`. |
| `iot/door/<id>/command` | service → Pi | `{"action": "open", "open_seconds": 5}` eller `{"action": "enroll_face", "user_id": 3}` |
| `iot/door/<id>/enroll` | Pi → service | `{"user_id": 3, "image": "<base64 JPEG>"}` |

`<id>` er `doors.device_id`, fx `door-hoveddoer` og `door-oekonomi`.

**Afvisningsårsager** (`reason`): `unknown_card`, `inactive`, `expired`,
`locked`, `face_opt_out` (brug PIN), `no_face_enrolled`, `no_face_detected`,
`bad_image`, `face_mismatch`,
`no_pin`, `wrong_pin`, `no_permission`, `bad_request`, `unknown_door`.

**Ansigter – beregnes på serveren:** Pi Zero'en tager et billede (fx 640×480
JPEG, ~30–100 KB, maks. 512 KB) og sender det base64-kodet. Servicen finder
ansigterne med `face_recognition` (dlib, HOG), bruger det **største** ansigt
(personen tættest på kameraet) og laver embeddingen (128 floats). Et match er
en euklidisk afstand ≤ `FACE_THRESHOLD` (0,6). En `embedding` sendt af døren
ignoreres, så en kompromitteret dør ikke kan genbruge en stjålet embedding.
Tilmelding via døren kræver præcis ét ansigt i billedet. Billedet gemmes ikke.

Målt lokalt (640×480 JPEG): ~200 ms pr. billede med ansigt, ~80 ms uden;
første billede efter start ~0,8 s, fordi dlib-modellerne indlæses.

**PIN:** Den gemmes som bcrypt-hash (`password_hash()` i PHP virker direkte).
Efter `MAX_PIN_ATTEMPTS` (3) forkerte forsøg låses kontoen i
`LOCKOUT_MINUTES` (5).

## Sikkerhed

- Dørene forbinder kun over TLS (8883). Servicen bruger den lokale listener.
- Servicen har sin egen MQTT-bruger. ACL'en tillader kun dør-brugeren at
  **skrive** `request`, `status` og `enroll` og at **læse** `response` og
  `command`. En dør kan altså ikke selv sende et "åbn"-svar.
- Hemmeligheder ligger i `/etc/lockdin/access-service.env` (kun root).
  Servicen kører som `DynamicUser` uden skriveadgang til disken.
- **Kendt begrænsning:** Alle døre deler én MQTT-bruger, så en kompromitteret
  dør kan udgive sig for en anden dør. Næste skridt er en bruger pr. dør med
  `pattern … iot/door/%u/…` i ACL'en.

## Test

Lokalt (logikken kræver intet – dlib erstattes af en falsk encoder; MQTT-testen
kræver `mosquitto` + `paho-mqtt`):

```bash
cd services/access_service
python3 -m unittest -v test_access_service.py
```

På VM'en efter `terraform apply`. Kopiér et par billeder af et ansigt op
(`scp`), tilmeld det til receptionisten, og kør så demoen:

```bash
sudo systemctl status lockdin-access
sudo journalctl -u lockdin-access -f        # i et andet vindue

SIM="/opt/lockdin/face-venv/bin/python /opt/lockdin/simulate_door.py --user iot_device --password '<mqtt_password>'"
$SIM --device door-hoveddoer --enroll <user_id> --image mette1.jpg
$SIM --device door-hoveddoer --card <kort-uid> --image mette2.jpg   # → ÅBN
$SIM --device door-oekonomi  --card <kort-uid> --image mette2.jpg   # → AFVIST: no_permission
$SIM --device door-hoveddoer --listen                         # se fjernåbninger
```

Fjernåbning uden admin-siden:

```sql
INSERT INTO door_commands (door_id, action, requested_by, reason)
VALUES (1, 'open', 'it-admin', 'Glemt kort, genkendt på kamera');
```

## Konfiguration (miljøvariabler)

| Variabel | Standard |
|---|---|
| `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | sættes af Terraform |
| `MQTT_HOST`, `MQTT_PORT`, `MQTT_USER`, `MQTT_PASSWORD` | `127.0.0.1`, `1883`, `access_service` |
| `FACE_THRESHOLD` | `0.6` |
| `MAX_PIN_ATTEMPTS`, `LOCKOUT_MINUTES` | `3`, `5` |
| `OPEN_SECONDS` | `5` |
| `LOG_LEVEL` | `INFO` |
