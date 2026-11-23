# LockdIn – mockups af admin-portalen

Statiske HTML-mockups (ingen backend) af den portal, kundens IT-team bruger til
at administrere profiler, døre og adgangslog. Åbn `index.html` i en browser.

| Fil | Side |
|---|---|
| `login.html` | Log ind (kun fra whitelistede IP'er) |
| `profiler.html` | Oversigt over brugere |
| `profil.html` | Redigér én bruger (kort, PIN, ansigt, status) |
| `doere.html` | Raspberry Pi-døre og adgang pr. rolle |
| `adgangslog.html` | Alle adgangsforsøg |
| `support.html` | Fjernsupport via kamera og midlertidige kort |

`lockdin.css` indeholder design-tokens (farver, afstande, lyst/mørkt tema) og alle
komponenter (`.li-`-klasser). Den er tænkt som stylesheet til den rigtige PHP-side.

Design-systemet (farver, typografi, komponent-guides):
https://claude.ai/artifact/TkQbSza8DxsDG1D8YLmBWv

Data og navne er opdigtede eksempler.
