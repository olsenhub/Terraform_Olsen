# Udvidet IoT – Adgangskontrol (Terraform / Azure)

3. semester IT-teknolog (Zealand), eksamen "Udvidet IoT-projekt prøve" (20 ECTS).
Gruppe på 3. Denne mappe er cloud-/netværksdelen af projektet.

## Projektet
**Case:** Mellemstor dansk bankfilial vil erstatte fysiske nøgler/gamle kort med
IoT-adgangskontrol med rollebaserede rettigheder, central administration og
logning af alle adgangsforsøg (sporbarhed).

**Adgangsmetoder:**
- Primær: RFID-kort + ansigtsgenkendelse
- Alternativ: RFID-kort + PIN (numpad), hvis ansigtsgenkendelse fejler/fravælges
- Glemt kort: support verificerer via kamera og åbner døren eller udsteder midlertidigt kort

**Roller:**

| Rolle | Hoveddør | Reception | Rådgivning | Økonomi | Serverrum |
|---|:-:|:-:|:-:|:-:|:-:|
| Receptionist | ✓ | ✓ | | | |
| Bankrådgiver | ✓ | ✓ | ✓ | | |
| Økonomimedarbejder | ✓ | ✓ | | ✓ | |
| IT-ansvarlig | ✓ | ✓ | ✓ | ✓ | ✓ |
| Gæst/håndværker | midlertidigt kort fra support | | | | |

**Proof of concept:** 2 døre – hoveddør og økonomiafdeling. Demo: receptionisten
kommer ind ad hoveddøren, men afvises ved økonomiafdelingen.

**Krav:** central rettighedsstyring, skalerbar til flere døre/filialer uden
redesign, alle adgangsforsøg logges, leveres som SaaS, sikker, pålidelig,
acceptabel ydeevne.

**Problemformulering:** Hvordan kan der designes og udvikles en sikker og
skalerbar IoT-baseret adgangskontrol med rollebaserede adgangsrettigheder, der
bruger ansigtsgenkendelse kombineret med RFID som primær adgangsmetode, RFID med
PIN som alternativ og fjernsupport, når brugeren mangler sit kort, og hvordan kan
den tilhørende netværks- og cloudinfrastruktur i Azure designes, udrulles og
overvåges, så løsningen kan leveres som SaaS og er sikker, pålidelig og har en
acceptabel ydeevne?

## Arkitektur (planlagt)
- **Dør-enhed:** Raspberry Pi (evt. Zero) + kamera + numpad + RFID-læser +
  elektromagnetisk lås. Ide: mikrofon/højttaler til support i stedet for tlf.nr.
- **Kommunikation:** MQTT over TLS (Mosquitto, port 8883) mellem Pi og cloud.
- **Database:** MariaDB – brugere, kort-UID, døre, adgangsrettigheder, adgangslog
  (senere evt. billeder/ansigtsdata, PIN, gæster).
- **Cloud:** Azure via Terraform (evt. Ansible), monitoring med Prometheus/Grafana,
  IDS med Suricata (+ Discord-alerts), ønske om backup-server.
- **Support:** web-/HTML-side til fjernverificering og døråbning.

## Denne Terraform-opsætning
- Én Ubuntu 22.04-VM i Azure (`main.tf`), alt installeres via cloud-init-scripts
  i `scripts/` (LAMP, Suricata, Discord-alerts, monitoring, GeoIP, MQTT).
- `database.tf`: adgangskontrol-skemaet (`doors`, `users`, `door_access`,
  `access_log`) + app-bruger, kørt over SSH via `terraform_data`.
- `phpmyadmin.tf`: phpMyAdmin over SSH-provisioner, kun `Require local` – tilgås via
  SSH-tunnel (`terraform output phpmyadmin_tunnel`).
- Grafana-dashboards i `dashboards/`.
- `access_service.tf`: Python-daemonen `lockdin-access` (kode i
  `services/access_service/`, tests med `python3 -m unittest`) – MQTT
  `iot/door/<device_id>/request|response|status|command|enroll` ↔ MariaDB. Skriver
  også Mosquitto-ACL'en (overskriver cloud-init's).
- `webadmin.tf`: admin-panelet (PHP i `webadmin/app/`, kun `public/` serveres) på
  Apache-vhost 8443 med TLS (MQTT-certifikatet) og `Require ip` = NSG-reglen
  `Allow-WebAdmin` (`customer_admin_ips` + admin-IP'er). Konfig i
  `/etc/lockdin-webadmin/config.json`. Første admin fra `webadmin_admin_*` i tfvars.
  Panelet skriver kun i DB; fjernåbning/ansigt går via `door_commands` → servicen.
- `webadmin/mockups/`: statiske mockups; design-system "LockdIn"
  på https://claude.ai/artifact/TkQbSza8DxsDG1D8YLmBWv.
- Hemmeligheder ligger i `terraform.tfvars` (gitignored). Nye variabler skal også
  tilføjes til `terraform.tfvars.example` uden rigtige værdier.

**Vigtigt:** Ændringer i cloud-init (`custom_data`/scripts) **genskaber hele VM'en**.
Ændringer der skal ramme den kørende VM (fx DB-skema) skal gå via SSH-provisioner
som i `database.tf`. Nye kolonner på eksisterende tabeller kræver `ALTER TABLE`.

## Rapport (formkrav)
Forside (titel, deltagere, vejleder), indholdsfortegnelse, indledning inkl.
problemformulering, metode, analyse, dokumentation af udviklingsproces og
afprøvning, konklusion, kildeliste, bilag (kode som zip).
Maks. 30 normalsider à 2.400 tegn (3 personer), ekskl. forside/bilag.
Eksamen: 10 min projekt + 10 min teknisk løsning (gruppe), 15 min individuel.
Bedømmes på læringsmålene i *Udvidet netværksteknologi* (sikkert netværksdesign,
protokoller, drift/overvågning) og *Udvidet indlejrede systemer* (dataflows,
open source-værktøjer, integration lokalt/cloud, machine learning, ydeevne).

## Tidsplan 2026
- 18.–24. nov: infrastruktur oppe, database, ansigtsgenkendelse virker på laptop
- 25. nov–2. dec: hardware-integration (simulering → rigtig Pi)
- 3.–8. dec: test og målinger (genkendelsesrate, svartid, broker-nedbrud) + rapport
- 9. dec: intern aflevering/gennemlæsning
- **10. dec kl. 12:00: aflevering**

## Kilder
- Brainstorm/kalender: Google Doc "Udvidet IOT 2026"
  (https://docs.google.com/document/d/15zAEwNHHGyIRVG6__ZasLMrZX7SaUmx68SeG8M04qhY)
- Studieordning: `~/Downloads/Samlet-studieordning-IT-teknolog-2025.pdf`
- Problemformulering: `~/Desktop/IT-teknolog/3. Semester/Udvidet IOT/`
