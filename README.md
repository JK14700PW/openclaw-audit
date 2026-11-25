# openclaw-audit · skill `/audyt-hosta`

Skill dla **Claude Code**, który zdalnie, przez SSH, przeprowadza **audyt bezpieczeństwa serwera Linux**
skillem `healthcheck` z [OpenClaw](https://github.com/openclaw/openclaw). Sprawdza trzy obszary:

| Obszar | Co jest sprawdzane |
|---|---|
| 🔐 **Serwer SSH** | efektywna konfiguracja `sshd -T`: logowanie hasłem i na roota, forwarding, `AllowUsers`, prawa `authorized_keys`, fail2ban |
| 🧱 **Zapora sieciowa** | `ufw`, `iptables`, `nftables`, usługi nasłuchujące na interfejsach publicznych, ekspozycja gateway OpenClaw |
| 🤖 **`.claude/settings.json`** | reguły `deny/ask/allow`, tryb `bypassPermissions`, hooki `PreToolUse`, sekrety w `env`, prawa pliku |

Wystarczy przygotować **jeden plik z danymi maszyny** i wpisać w Claude Code `/audyt-hosta`.
Skill sprawdzi wymagania, przygotuje środowisko (prywatny Node.js i OpenClaw w jednym katalogu, bez `sudo`),
przeprowadzi audyt, pobierze raport na Twój komputer i **posprząta maszynę**, sprawdzając, czy nic nie zostało.

> Projekt zaliczeniowy (Projekt 1) szkolenia z wykorzystania narzędzi AI, Politechnika Warszawska.
> Treść zadania: *uruchom dedykowany skill healthcheck w OpenClaw w celu przeprowadzenia audytu zabezpieczeń
> serwera SSH, konfiguracji zapory sieciowej (firewall) oraz weryfikacji uprawnień w pliku .claude/settings.json.*

**🧭 Instalacja krok po kroku (prezentacja):** [`docs/instalacja-krok-po-kroku.html`](docs/instalacja-krok-po-kroku.html):
12 slajdów od `git clone` do otwarcia raportu, z poleceniami do skopiowania. Pobierz plik i otwórz go
w przeglądarce. Nawigacja: strzałki ← →, pełny ekran: **F**.

**📄 Raport końcowy projektu:** [`docs/raport-koncowy.html`](docs/raport-koncowy.html) ([jak go otworzyć](#gdzie-jest-raport))

---

## Spis treści

1. [Co trzeba przygotować](#co-trzeba-przygotować)
2. [Instalacja skilla](#instalacja-skilla)
3. [Plik z danymi maszyny](#plik-z-danymi-maszyny)
4. [Uruchomienie](#uruchomienie)
5. [Gdzie jest raport](#gdzie-jest-raport)
6. [Jak to działa](#jak-to-działa)
7. [Bezpieczeństwo](#bezpieczeństwo)
8. [Ograniczenia](#ograniczenia)
9. [Struktura repozytorium](#struktura-repozytorium)

---

## Co trzeba przygotować

### Na swoim komputerze
| Wymaganie | Uwagi |
|---|---|
| [Claude Code](https://claude.com/claude-code), **zalogowany** | do wywołania skilla `/audyt-hosta`; logowanie: `claude`, potem `/login` (konto z subskrypcją). Bez Claude Code narzędzie działa też z terminala |
| `bash`, `ssh`, `tar` | Linux i macOS mają je wbudowane. Na Windows: [Git for Windows](https://gitforwindows.org/) (Git Bash) |
| klucz prywatny SSH do maszyny | plik `.pem` lub `id_ed25519`; tylko ścieżka do niego trafia do konfiguracji |

### Na audytowanej maszynie
Niczego nie trzeba instalować ręcznie. Skill **sam sprawdza wymagania** (`--check`) i pokazuje tabelę
OK / UWAGA / BRAK z gotowym poleceniem naprawy przy każdym braku. Node.js i OpenClaw pobiera sam,
do własnego katalogu, bez `sudo` i bez zmiany systemowego Node.

| Wymaganie | Kto zapewnia | Uwagi |
|---|---|---|
| dostęp SSH kluczem | **Ty** | adres, port, użytkownik i klucz podajesz w pliku z danymi |
| **dostęp do modelu AI** (jeden z dwóch) | **Ty** | **a)** zalogowany na maszynie Claude Code (`claude` → `/login`), tryb `claude-cli`<br>**b)** klucz API Anthropic w pliku na Twoim komputerze, tryb `anthropic-api-key` |
| Node.js 24 LTS | skill | prywatna kopia `v24.22.3` z nodejs.org, weryfikowana SHA-256, w `~/.openclaw-audit` |
| OpenClaw | skill | przypięta wersja, z kontrolą SHA-256 ocenionego skilla `healthcheck` |
| `curl`, `tar`, `xz`, `python3` | zwykle są w systemie | brak = `BRAK` w tabeli z poleceniem `apt-get install ...` |
| `sudo` bez hasła (`sudo -n`) | opcjonalne | tylko do **odczytu** `sshd -T` i reguł zapory; bez niego te kontrole dostają `SKIP` |
| internet (HTTPS) do nodejs.org i registry.npmjs.org | sieć | sprawdzane w tabeli wymagań |
| ~1,5 GB wolnego miejsca w `$HOME` | system | środowisko zajmuje ok. 1,2 GB (usuwane po audycie) |

Przykładowa tabela wymagań:

```text
OK     sudo -n                      dostępne (tylko do odczytu sshd -T i reguł zapory)
OK     sieć: nodejs.org             HTTPS osiągalne
INFO   Node (prywatny)              brak — zostanie pobrany przy instalacji
INFO   Node (systemowy)             v24.18.0 — nie jest używany ani zmieniany
BRAK   Claude Code                  niezalogowany
                                    ↳ na maszynie: claude  →  /login   albo AUTH_MODE=anthropic-api-key
WYNIK: brakuje wymagań (BRAK) — uzupełnij według wskazówek ↳
```

### Co zostaje na maszynie
Narzędzie trzyma **cały swój ślad w jednym katalogu** `~/.openclaw-audit`: prywatny Node, OpenClaw,
cache npm, stan i poświadczenia OpenClaw (`OPENCLAW_HOME`), skrypty i wyniki. Nie korzysta z `~/.openclaw`
ani `~/.npm`. Przy `CLEANUP=yes` (domyślnie) po pobraniu wyników:

1. usuwa `~/.openclaw-audit` i sesje Claude Code utworzone przez OpenClaw (`~/.claude/projects/*openclaw-audit*`),
2. porównuje listę ścieżek w katalogu domowym ze **zdjęciem sprzed pierwszej instalacji**,
3. zapisuje wynik w raporcie (część C): „brak nowych ścieżek ✅” albo listę śladów do przejrzenia.

`CLEANUP=no` zostawia środowisko na kolejne, szybsze audyty. Usunięcie później: `--uninstall`.

---

## Instalacja skilla

```bash
git clone https://github.com/<użytkownik>/<repozytorium>.git
cd <repozytorium>
bash install-skill.sh
```

Skrypt kopiuje skill do `~/.claude/skills/audyt-hosta`, więc jest dostępny w każdym projekcie.
Wariant tylko dla jednego projektu: `bash install-skill.sh --project <katalog_projektu>`.
Po instalacji **uruchom nową sesję Claude Code**, żeby skill się pojawił. Jeśli przy pierwszym poleceniu
pojawi się `Please run /login` albo `API Error: 401 … OAuth access token is invalid`, to Claude Code na Twoim
komputerze nie jest zalogowany (albo logowanie wygasło). Wpisz w tej sesji `/login`, zaloguj się w przeglądarce
i wywołaj skill ponownie. Ten błąd nie dotyczy audytowanej maszyny.

**Brak połączenia z maszyną.** Gdy SSH się nie łączy, skill zatrzymuje się przed jakąkolwiek zmianą
(kod wyjścia 4) i podaje przyczynę oraz co zrobić, np.:

```text
BŁĄD POŁĄCZENIA z azureuser@203.0.113.10:50000
  Przyczyna:  Maszyna nie odpowiada (timeout). Najczęściej jest wyłączona, ale może to być też zły adres
              albo port zablokowany przez zaporę chmury (NSG).
  Co zrobić:  Uruchom maszynę (Azure ML Studio → Compute → instancja → Start), odczekaj 2–3 minuty
              i spróbuj ponownie. Sprawdź AUDIT_HOST i AUDIT_PORT.
WYNIK: brak połączenia z maszyną — niczego nie wysłano ani nie zmieniono.
```

Rozpoznawane przyczyny: maszyna nie odpowiada (timeout), port bez SSH (odmowa), nieznany adres, odrzucony
klucz lub użytkownik, zmieniony klucz hosta, zbyt szerokie uprawnienia pliku klucza, brak trasy sieciowej
i zerwane połączenie.

**Pytania o zgodę.** Claude Code przed każdym poleceniem powłoki pokazuje jego dokładny tekst i pyta
`Do you want to proceed?`. Przeczytaj polecenie i wybierz `1. Yes`: to zgoda na to jedno polecenie.
W trakcie audytu pytań jest kilka: sprawdzenie wymagań, audyt, odczyt raportu i ręczna weryfikacja.
To celowa bramka human-in-the-loop. Opcja „don't ask again” zapisuje stałą regułę w ustawieniach
Claude Code, więc wybieraj ją świadomie.

---

## Plik z danymi maszyny

Wszystkie dane potrzebne do audytu są w **jednym pliku**. Skopiuj wzór i uzupełnij:

```bash
cp config.example.env ~/audyty/moja-maszyna.env
```

| Klucz | Wymagany | Opis | Przykład |
|---|:---:|---|---|
| `AUDIT_HOST` | ✅ | adres IP lub nazwa maszyny | `203.0.113.10` |
| `AUDIT_PORT` | | port SSH (domyślnie `22`) | `50000` |
| `AUDIT_USER` | ✅ | użytkownik SSH | `azureuser` |
| `AUDIT_SSH_KEY` | ✅ | **ścieżka** do klucza prywatnego SSH | `D:\klucze\maszyna.pem` |
| `AUTH_MODE` | | `claude-cli` (domyślnie) albo `anthropic-api-key` | `claude-cli` |
| `ANTHROPIC_API_KEY_FILE` | przy `anthropic-api-key` | **ścieżka** do pliku zawierającego wyłącznie klucz API | `~/.secrets/anthropic_key` |
| `ANTHROPIC_API_KEY` | | alternatywnie klucz wpisany wprost (niezalecane) | |
| `AUDIT_MODEL` | | model, puste = domyślny | `claude-opus-5-5` |
| `REPORTS_DIR` | | gdzie zapisać raporty, względnie do katalogu pliku | `./raporty` |
| `AGENT_TIMEOUT` | | limit czasu pracy agenta w sekundach | `900` |
| `CLEANUP` | | `yes` (domyślnie): usuń środowisko po audycie; `no`: zostaw na kolejne audyty | `yes` |
| `OPENCLAW_VERSION` | | przypięta wersja OpenClaw (puste = domyślna narzędzia) | `2026.11.10` |
| `HEALTHCHECK_SHA256` | | SHA-256 ocenionego `skills/healthcheck/SKILL.md` | *(domyślna)* |
| `NODE_VERSION` | | wersja prywatnego Node.js (puste = domyślna) | `24.22.3` |
| `NODE_SHA256_X64`, `NODE_SHA256_ARM64` | | SHA-256 archiwów Node z `SHASUMS256.txt` | *(domyślne)* |

Puste wartości oznaczają wartości domyślne narzędzia: przypięte i sprawdzone wersje.

Przykład minimalny:

```ini
AUDIT_HOST=203.0.113.10
AUDIT_PORT=50000
AUDIT_USER=azureuser
AUDIT_SSH_KEY=D:\klucze\maszyna.pem
```

> ⚠️ **Nie commituj tego pliku.** `.gitignore` blokuje `*.env` (poza wzorem), `*.pem` i katalogi raportów.
> Plik jest **parsowany, a nie wykonywany**: nieznane klucze i niepoprawne wartości (np. `;` w adresie)
> przerywają działanie, więc przez plik nie da się wstrzyknąć polecenia.

---

## Uruchomienie

### W Claude Code (zalecane)

```
/audyt-hosta ~/audyty/moja-maszyna.env
```

Jeśli nie podasz ścieżki, Claude o nią zapyta. Przebieg:

1. **Walidacja, połączenie i wymagania:** Claude pokazuje podsumowanie konfiguracji i tabelę wymagań. Przy brakach podaje polecenia naprawy i się zatrzymuje. Na tym etapie na maszynie nic się nie zmienia i nic nie zostaje.
2. **Pytanie o zgodę i tryb:** pełny audyt, tylko audyt, tylko przygotowanie środowiska albo usunięcie środowiska.
3. **Audyt** działa w tle: pierwszy przebieg z pobraniem Node i OpenClaw trwa około 5–7 minut, kolejne około 3–5 minut.
4. **Sprzątanie** (przy `CLEANUP=yes`): usunięcie `~/.openclaw-audit` i kontrola śladów.
5. **Podsumowanie:** liczby PASS/FAIL/WARN, najważniejsze ustalenia dla każdego obszaru, miejsca, w których agent zakwestionował reguły, ręczna weryfikacja 2–3 kluczowych twierdzeń agenta, stan maszyny po audycie i link do raportu.

Skill **nie wprowadza poprawek**: plan naprawczy jest wyłącznie rekomendacją. Skill uruchamia tylko
użytkownik (`disable-model-invocation: true`), bo działa na zdalnej maszynie.

### Z terminala (bez Claude Code)

```bash
bash run-audit.sh -c moja-maszyna.env --validate      # tylko sprawdzenie pliku
bash run-audit.sh -c moja-maszyna.env --check         # + test SSH i tabela wymagań (nic nie zostawia)
bash run-audit.sh -c moja-maszyna.env                 # wymagania + środowisko + audyt + raport + sprzątanie
bash run-audit.sh -c moja-maszyna.env --skip-install  # tylko audyt (środowisko już jest)
bash run-audit.sh -c moja-maszyna.env --install-only  # tylko przygotowanie środowiska
bash run-audit.sh -c moja-maszyna.env --uninstall     # usunięcie środowiska + kontrola śladów
```

W PowerShell poprzedź polecenie `bash` (wymaga Git Bash w `PATH`).

---

## Gdzie jest raport

### Raport z Twojego audytu
Każdy przebieg tworzy na Twoim komputerze nowy katalog:

```
<REPORTS_DIR>/<host>_<RRRRMMDD-GGMMSS>/
├── REPORT.html          ← raport do otwarcia w przeglądarce (jeden plik, offline)
├── REPORT.md            ← ten sam raport w Markdown: A (kontrole) + B (agent) + C (ślad na maszynie)
├── checks.tsv           ← wyniki kontroli deterministycznych
├── healthcheck.md       ← pełna odpowiedź skilla healthcheck
├── post_check.txt       ← czy audyt niczego nie zmienił w konfiguracji maszyny
├── preflight.txt        ← tabela wymagań sprzed audytu
├── cleanup.txt          ← co usunięto i czy zostały ślady
├── prompt.md            ← polecenie przekazane agentowi
├── evidence/            ← surowe dowody (sshd -T, ufw, iptables, nft, porty, settings.json z maskowanym env)
└── openclaw_log.txt     ← log OpenClaw
```

`REPORTS_DIR` domyślnie to `./reports` **obok pliku z danymi maszyny**. Ścieżkę do raportu podaje
ostatnia linia wyjścia, a w Claude Code dostajesz link. Przy `CLEANUP=no` kopia przebiegu zostaje też
na maszynie, w `~/.openclaw-audit/runs/`.

> Raporty zawierają adresy i konfigurację maszyny, więc **nie publikuj ich** bez anonimizacji.

### Raport końcowy tego projektu
[`docs/raport-koncowy.html`](docs/raport-koncowy.html) to opracowany, zanonimizowany raport z audytu
maszyny Azure ML wykonanego tym narzędziem. Zawiera ocenę OpenClaw, wyniki, weryfikację agenta,
rekomendacje i wnioski. GitHub nie wyświetla plików HTML jako stron, więc:

- **pobierz:** otwórz plik na GitHubie → *Download raw file* → otwórz w przeglądarce (działa offline),
- albo **GitHub Pages:** *Settings → Pages → Branch `main`, folder `/docs`*; raport będzie pod adresem
  `https://<użytkownik>.github.io/<repozytorium>/raport-koncowy.html`.

Ocena OpenClaw przed użyciem (checklista z warsztatu): [`docs/ocena-openclaw.md`](docs/ocena-openclaw.md).

---

## Jak to działa

```
 Twój komputer                                   Audytowana maszyna (SSH)
 ─────────────                                   ────────────────────────
 /audyt-hosta  ─►  run-audit.sh
                     │ 0. walidacja pliku, test SSH
                     │ 1. wymagania (strumieniowo) ──►  preflight.sh → tabela OK/BRAK (nic nie zapisuje)
                     │ 2. skrypty + zdjęcie stanu  ──►  ~/.openclaw-audit/tool/, footprint.before
                     │ 3. środowisko               ──►  install.sh  → prywatny Node (SHA-256) + OpenClaw
                     │                                                (wersja przypięta, SHA-256 skilla,
                     │                                                 --ignore-scripts, bez sudo)
                     │ 4. audyt                    ──►  collect.sh  → dowody + kontrole PASS/FAIL (część A)
                     │                                  audit.sh    → openclaw agent --local
                     │                                                + skill healthcheck (część B)
                     │                                              → kontrola: czy nic się nie zmieniło
                     │ 5. pobranie wyników         ◄──  ~/.openclaw-audit/runs/<czas>/
                     │ 6. sprzątanie               ──►  cleanup.sh  → rm ~/.openclaw-audit, porównanie
                     ▼                                                ze zdjęciem stanu (część C)
               REPORT.md
```

- **Część A, kontrole deterministyczne:** około 25 reguł bez AI. Za każdym razem dają ten sam wynik i nadają się do porównań w czasie.
- **Część B, skill `healthcheck`:** agent ocenia kontekst, koryguje ważność ustaleń, dopisuje to, czego reguły nie przewidziały, i proponuje plan naprawczy. Wyniki części A dostaje jako drugą opinię.
- Skill `healthcheck` sam z siebie nie sprawdza `sshd_config` ani `.claude/settings.json`. Dlatego polecenie dla agenta ([`remote/prompt.md`](remote/prompt.md)) rozszerza jego zakres o te obszary i wskazuje zebrane dowody.

---

## Bezpieczeństwo

| Ryzyko | Zabezpieczenie |
|---|---|
| Podmiana paczki lub skilla | przypięta wersja `OPENCLAW_VERSION`; SHA-256 ocenionego `SKILL.md`, a przy niezgodności instalacja się przerywa |
| Podmiana Node.js | prywatny Node w przypiętej wersji, archiwum weryfikowane SHA-256 przed rozpakowaniem |
| Skrypty instalacyjne npm | `npm install --ignore-scripts`: żadna paczka nie wykonuje kodu przy instalacji |
| Zmiany w systemie przez instalację | brak `sudo`; wszystko w `~/.openclaw-audit`; systemowy Node, `~/.openclaw` i `~/.npm` nietknięte; sprzątanie z kontrolą śladów |
| Automatyczne „naprawianie” wymagań | braki (np. pakiety apt) są tylko zgłaszane z poleceniem naprawy, nie instalowane |
| Agent AI z dostępem do powłoki | polecenie zabrania zmian i `sudo`; dowody wymagające uprawnień zbiera skrypt, nie agent; po audycie porównanie `sshd -T`, `ufw` i SHA-256 plików `settings.json` |
| Wystawienie panelu OpenClaw | gateway nie jest uruchamiany (`agent --local`), `gateway.bind=loopback`, brak kanałów |
| Wyciek klucza API | klucz czytany z pliku, przesyłany przez **stdin SSH**, a do OpenClaw przez zmienną środowiskową (nie przez argumenty widoczne w `ps`); zapisany tylko w `~/.openclaw-audit` (prawa 600) i usuwany przy sprzątaniu |
| Wyciek sekretów do modelu | wartości `env` z `settings.json` są maskowane (`***`) |
| Wstrzyknięcie przez plik konfiguracji | plik parsowany jako `KLUCZ=wartość`, lista dozwolonych kluczy, walidacja wartości |
| Publikacja prywatnych danych | `.gitignore`, skaner [`scripts/check-secrets.sh`](scripts/check-secrets.sh) w hooku pre-commit i w CI |

Przed własnym commitem włącz hook i dopisz swoje prawdziwe wartości do lokalnego pliku wzorców:

```bash
git config core.hooksPath .githooks
printf '%s\n' "<twój-adres-ip>" "<nazwa-maszyny>" > .private-patterns   # plik jest w .gitignore
bash scripts/check-secrets.sh
```

---

## Ograniczenia

- **Polecenie dla agenta nie jest bramką bezpieczeństwa.** Zakaz zmian to instrukcja dla modelu: w testach agent raz użył `sudo -n true` mimo zakazu (sam to zgłosił). Kontrola po audycie tylko **wykrywa** zmiany. Twardą granicę daje konto bez `sudo`.
- **Wynik agenta jest niedeterministyczny:** kolejne przebiegi różnią się liczbą ustaleń i ocenami ważności. Do porównań służy część A.
- **Zapora chmurowa** (np. Azure NSG, AWS Security Group) jest niewidoczna z wnętrza maszyny. Kontrole dotyczą zapory hosta.
- Wynik agenta w trybie `anthropic-api-key` i `claude-cli` może się różnić (inny model domyślny i kontekst). Oba tryby przetestowano na Ubuntu 22.04; w trybie z kluczem sprawdzono, że klucz nie zostaje w wynikach, logach, historii powłoki, `/tmp` ani w dzienniku systemowym.
- **Kontrola śladów** porównuje listę ścieżek w katalogu domowym (głębokość 3), a nie zawartość plików. W trybie `claude-cli` Claude Code może zaktualizować istniejący `~/.claude.json` (statystyki uruchomień). Narzędzie tego pliku nie edytuje. Nowe kopie `~/.claude/backups/.claude.json.backup.*` utworzone w trakcie audytu są usuwane.
- Testowane na Ubuntu 22.04 (x86_64). Inne dystrybucje mogą wymagać dostosowania `collect.sh` i `preflight.sh`.

---

## Struktura repozytorium

| Ścieżka | Zawartość |
|---|---|
| [`SKILL.md`](SKILL.md) | definicja skilla Claude Code `/audyt-hosta` |
| [`config.example.env`](config.example.env) | **wzór pliku z danymi maszyny** |
| [`install-skill.sh`](install-skill.sh) | instalacja skilla w `~/.claude/skills` |
| [`run-audit.sh`](run-audit.sh) | orkiestrator: walidacja, SSH, instalacja, audyt, pobranie wyników |
| [`remote/env.sh`](remote/env.sh) | wspólne ścieżki: wszystko w `~/.openclaw-audit` |
| [`remote/preflight.sh`](remote/preflight.sh) | tabela wymagań z poleceniami naprawy; zdjęcie stanu katalogu domowego |
| [`remote/install.sh`](remote/install.sh) | prywatny Node + OpenClaw (idempotentnie, bez sudo) |
| [`remote/cleanup.sh`](remote/cleanup.sh) | usunięcie środowiska i kontrola śladów |
| [`remote/collect.sh`](remote/collect.sh) | zbieranie dowodów i kontrole deterministyczne |
| [`remote/audit.sh`](remote/audit.sh) | uruchomienie skilla `healthcheck` i kontrola braku zmian |
| [`remote/prompt.md`](remote/prompt.md) | polecenie dla agenta |
| [`lib/build-report.sh`](lib/build-report.sh), [`lib/report-template.html`](lib/report-template.html) | składanie `REPORT.md` i `REPORT.html` (dane w base64, bezpieczne renderowanie tekstu agenta) |
| [`scripts/check-secrets.sh`](scripts/check-secrets.sh), [`.githooks/`](.githooks/) | skan sekretów i danych prywatnych |
| [`tests/test_config.sh`](tests/test_config.sh) | testy parsera pliku konfiguracji |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | CI: składnia, ShellCheck, testy, skan sekretów |
| [`docs/`](docs/) | prezentacja instalacji krok po kroku, raport końcowy (HTML) i ocena OpenClaw |

Testy lokalnie:

```bash
bash tests/test_config.sh
bash scripts/check-secrets.sh
```
