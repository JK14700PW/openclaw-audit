# Ocena OpenClaw i skilla `healthcheck` przed instalacją

Data: 2026-11-25. Metoda: checklista oceny cudzego rozszerzenia z warsztatu (część „Skille, MCP”).
Maszyna docelowa: Azure ML compute instance `<host>:50000` (Ubuntu 22.04, Node 24.18.0).

| Sprawdź | Pytanie | Ustalenie |
|---|---|---|
| Źródło | kto pisze i utrzymuje | github.com/openclaw/openclaw, organizacja OpenClaw (fundacja non-profit wg README). Opiekunowie paczki npm: `steipete`, `vincentkoc`. Jest `SECURITY.md` z kanałem zgłoszeń. |
| Licencja | czy pozwala na nasze użycie | MIT — tak. |
| Uprawnienia | do czego ma dostęp proces | Agent wykonuje polecenia powłoki na hoście z uprawnieniami użytkownika (`sandbox.mode` domyślnie wyłączony). Na tej maszynie `azureuser` ma `sudo NOPASSWD` → w praktyce pełny dostęp do systemu. **Ryzyko wysokie.** |
| Kod | co robi, dokąd wychodzi sieć | Paczka npm ma skrypty `preinstall`/`postinstall` (wykonują kod przy instalacji) i ~70 zależności. Sieć: dostawca modelu (cała rozmowa, w tym wyniki poleceń), codzienne sprawdzanie wersji (`update.checkOnStart`). Skill `healthcheck` to sam `SKILL.md` (2909 B), bez skryptów i bez adresów URL. |
| Zakres danych | co dostaje i co zwraca | Skill uruchamia tylko polecenia odczytowe: `openclaw security audit --deep`, `gateway status`, `doctor --lint`, `/etc/os-release`, `ss -ltnup`, `ufw status`/`nft list ruleset`, `systemctl status ssh`, `lsblk -f`. Wyniki trafiają do modelu → nie wolno, by w outputach były sekrety. |
| Aktualizacje i wersja | czy da się przypiąć | Tak: `openclaw@2026.11.10` (latest, wydana 2026-11-25; `extended-stable` = 2026.10.33). Przypinamy dokładną wersję. |
| Izolacja | czy uruchomimy w kontenerze | Audyt hosta wymaga dostępu do hosta, więc kontener nie wchodzi w grę. Zamiast tego: gateway tylko na loopback (`127.0.0.1:18789`), dostęp przez tunel SSH, zatwierdzanie poleceń, brak kanałów (WhatsApp/Telegram). |

## Ocena treści `SKILL.md` (ślady z ćwiczenia o złośliwym skillu)

- `description` jest neutralny, bez dyrektyw do agenta („ignoruj instrukcje”, znaczniki itp.) — **brak śladów złośliwości**.
- Reguły skilla: „Ask before state-changing actions”, „Never print secrets”, nie zmieniać SSH/firewalla przed potwierdzeniem ścieżki dostępu. To **instrukcje dla modelu, a nie egzekwowane bramki** — podobnie jak prośba w CLAUDE.md.

## Luki skilla względem treści Projektu 1

| Wymaganie projektu | Pokrycie przez `healthcheck` |
|---|---|
| Konfiguracja serwera SSH | Częściowo: tylko `systemctl status ssh`. **Nie czyta `sshd -T` / `sshd_config`.** |
| Firewall | Tak: `ufw status`, `nft list ruleset`, `ss -ltnup`. |
| Uprawnienia w `.claude/settings.json` | **Brak.** Skill tego nie sprawdza. |

Wniosek: przy uruchomieniu trzeba w poleceniu do agenta jawnie rozszerzyć zakres o `sshd -T` i `~/.claude/settings.json`, a wyniki zweryfikować ręcznie (część A raportu: kontrole deterministyczne).

## Decyzja

**Używamy — warunkowo**, ponieważ wymaga tego zadanie, a skill jest czytelny i odczytowy. Warunki:
1. przypięta wersja `openclaw@2026.11.10`, instalacja przez npm (bez `curl | bash`),
2. gateway tylko na loopback, panel wyłącznie przez tunel SSH,
3. żadnych kanałów komunikacyjnych, żadnych dodatkowych skilli z ClawHub,
4. bez `openclaw security audit --fix` i bez `doctor --fix`,
5. każda zmiana konfiguracji systemu tylko po akceptacji człowieka,
6. po zakończeniu projektu: zatrzymanie gateway i decyzja o odinstalowaniu.
