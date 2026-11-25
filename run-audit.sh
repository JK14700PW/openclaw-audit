#!/usr/bin/env bash
# openclaw-audit — zdalny audyt bezpieczeństwa hosta skillem healthcheck (OpenClaw).
#
# Użycie:  bash run-audit.sh -c <plik.env> [tryb]
#   (brak)          wymagania → instalacja → audyt → raport → sprzątanie (gdy CLEANUP=yes)
#   --validate      tylko walidacja pliku konfiguracji (bez połączenia)
#   --check         walidacja + test SSH + sprawdzenie wymagań na maszynie (nic nie zmienia, nic nie zostawia)
#   --install-only  tylko przygotowanie środowiska (Node, OpenClaw) w ~/.openclaw-audit
#   --skip-install  tylko audyt (środowisko musi już być)
#   --uninstall     usunięcie wszystkiego, co narzędzie zainstalowało, z raportem śladów
# Kody wyjścia: 0 OK · 1 błąd audytu/wymagań · 2 błąd pliku konfiguracji · 4 brak połączenia SSH (z diagnozą)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$HERE/config.env"
MODE=full
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config) CONFIG="$2"; shift 2 ;;
    --install-only) MODE=install; shift ;;
    --skip-install) MODE=audit; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --check) MODE=check; shift ;;
    --validate) MODE=validate; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "Nieznana opcja: $1" >&2; exit 2 ;;
  esac
done

CONFIG="${CONFIG//\\//}"   # ścieżki Windows (D:\...) → D:/...
[ -f "$CONFIG" ] || { echo "Brak pliku konfiguracji: $CONFIG (wzór: config.example.env)" >&2; exit 2; }
CONFIG_DIR="$(cd "$(dirname "$CONFIG")" && pwd)"

# ---------- Wczytanie pliku konfiguracji ----------
# Plik jest PARSOWANY (KLUCZ=wartość), a nie wykonywany przez `source`, więc nie może uruchomić kodu.
ALLOWED="AUDIT_HOST AUDIT_PORT AUDIT_USER AUDIT_SSH_KEY OPENCLAW_VERSION HEALTHCHECK_SHA256
AUTH_MODE ANTHROPIC_API_KEY_FILE ANTHROPIC_API_KEY AUDIT_MODEL REPORTS_DIR AGENT_TIMEOUT
NODE_VERSION NODE_SHA256_X64 NODE_SHA256_ARM64 CLEANUP"
# Wartości domyślne (przypięte i ocenione)
OPENCLAW_VERSION=2026.11.10
HEALTHCHECK_SHA256=b41044aeb25afe95daa5c8ef6f2d6b8d197f6a0b113b0888deaa4dd69e42b59b
NODE_VERSION=24.22.3
NODE_SHA256_X64=4f2b175a6d53a5c617a80dba2676238a0688cef28c6da4eba35c7d844e66fcfb
NODE_SHA256_ARM64=6e51a2ada00f0011cc266f65d98922b403d7ad88f809ca2aa615a5fe1ce6e86c
AUTH_MODE=claude-cli; AUDIT_PORT=22; AUDIT_MODEL=; AGENT_TIMEOUT=900; REPORTS_DIR=./reports; CLEANUP=yes
ANTHROPIC_API_KEY=; ANTHROPIC_API_KEY_FILE=
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] \
    || { echo "Niepoprawna linia w $CONFIG: $line" >&2; exit 2; }
  k="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
  val="${val%%[[:space:]]#*}"; val="${val%"${val##*[![:space:]]}"}"
  [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]] && val="${BASH_REMATCH[1]}"
  [[ " ${ALLOWED//$'\n'/ } " == *" $k "* ]] || { echo "Nieznany klucz w $CONFIG: $k" >&2; exit 2; }
  [ -n "$val" ] || continue   # pusta wartość = wartość domyślna
  printf -v "$k" '%s' "$val"
done < "$CONFIG"

# Ścieżki: ~ → katalog domowy, \ → /, względne liczone od katalogu pliku konfiguracji
xp() { local p="${1//\\//}"; [ -z "$p" ] && return 0
  [ "${p#\~}" != "$p" ] && p="$HOME${p#\~}"
  case "$p" in /*|?:/*) ;; *) p="$CONFIG_DIR/$p" ;; esac; printf '%s' "$p"; }
AUDIT_SSH_KEY=$(xp "${AUDIT_SSH_KEY:-}")
ANTHROPIC_API_KEY_FILE=$(xp "$ANTHROPIC_API_KEY_FILE")
REPORTS_DIR=$(xp "$REPORTS_DIR")

# ---------- Walidacja ----------
bad() { echo "$1" >&2; exit 2; }
for v in AUDIT_HOST AUDIT_PORT AUDIT_USER AUDIT_SSH_KEY; do [ -n "${!v:-}" ] || bad "Brak $v w $CONFIG"; done
[[ "$AUDIT_PORT" =~ ^[0-9]+$ ]] || bad "AUDIT_PORT musi być liczbą"
[[ "$AUDIT_HOST" =~ ^[A-Za-z0-9.:-]+$ && "$AUDIT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || bad "Niepoprawny AUDIT_HOST lub AUDIT_USER"
[[ "$OPENCLAW_VERSION" =~ ^[0-9][0-9.]*$ && "$HEALTHCHECK_SHA256" =~ ^[0-9a-f]{64}$ ]] || bad "Niepoprawny OPENCLAW_VERSION lub HEALTHCHECK_SHA256"
[[ "$NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$NODE_SHA256_X64" =~ ^[0-9a-f]{64}$ && "$NODE_SHA256_ARM64" =~ ^[0-9a-f]{64}$ ]] \
  || bad "Niepoprawny NODE_VERSION lub NODE_SHA256_*"
[[ "$AGENT_TIMEOUT" =~ ^[0-9]+$ && "$AUDIT_MODEL" =~ ^[A-Za-z0-9._/:-]*$ ]] || bad "Niepoprawny AGENT_TIMEOUT lub AUDIT_MODEL"
[[ "$CLEANUP" =~ ^(yes|no)$ ]] || bad "CLEANUP musi być yes albo no"
[ -f "$AUDIT_SSH_KEY" ] || bad "Brak klucza SSH: $AUDIT_SSH_KEY"
case "$AUTH_MODE" in
  claude-cli) ;;
  anthropic-api-key)
    if [ -z "$ANTHROPIC_API_KEY" ]; then
      [ -f "$ANTHROPIC_API_KEY_FILE" ] || bad "AUTH_MODE=anthropic-api-key: podaj ANTHROPIC_API_KEY_FILE (istniejący plik) albo ANTHROPIC_API_KEY"
      ANTHROPIC_API_KEY=$(tr -d '\r\n' < "$ANTHROPIC_API_KEY_FILE")
    fi ;;
  *) bad "AUTH_MODE musi być claude-cli albo anthropic-api-key" ;;
esac

if [ "$MODE" = check ] || [ "$MODE" = validate ]; then
  echo "Konfiguracja: $CONFIG"
  echo "  maszyna:   $AUDIT_USER@$AUDIT_HOST:$AUDIT_PORT"
  echo "  klucz SSH: $AUDIT_SSH_KEY"
  echo "  OpenClaw:  $OPENCLAW_VERSION (SKILL.md sha256 ${HEALTHCHECK_SHA256:0:12}…), Node $NODE_VERSION (prywatny)"
  echo "  model:     $AUTH_MODE${AUDIT_MODEL:+ / $AUDIT_MODEL}$([ -n "$ANTHROPIC_API_KEY" ] && echo " (klucz API wczytany, ${#ANTHROPIC_API_KEY} znaków)")"
  echo "  raporty:   $REPORTS_DIR"
  echo "  sprzątanie po audycie: $CLEANUP, limit agenta: ${AGENT_TIMEOUT}s"
fi
[ "$MODE" = validate ] && exit 0

# ---------- Połączenie ----------
SSH=(ssh -i "$AUDIT_SSH_KEY" -p "$AUDIT_PORT" -o BatchMode=yes -o ConnectTimeout=20
     -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 "$AUDIT_USER@$AUDIT_HOST")
ROOT='~/.openclaw-audit'; TOOL="$ROOT/tool"
step() { printf '\n==> %s\n' "$*" >&2; }
upload() { tar -C "$HERE/remote" -cf - . | "${SSH[@]}" "mkdir -p $TOOL && chmod 700 $ROOT && tar -C $TOOL -xf - && chmod +x $TOOL/*.sh"; }
preflight() { cat "$HERE/remote/env.sh" "$HERE/remote/preflight.sh" | "${SSH[@]}" "AUTH_MODE='$AUTH_MODE' bash -s check"; }

# Czytelna diagnoza błędu połączenia: przyczyna + co zrobić. Kod wyjścia 4 = brak połączenia.
ssh_diagnose() {
  local out="$1" cause fix
  case "$out" in
    *"timed out"*|*"Operation timed out"*)
      cause="Maszyna nie odpowiada (timeout). Najczęściej jest wyłączona, ale może to być też zły adres albo port zablokowany przez zaporę chmury (NSG)."
      fix="Uruchom maszynę (Azure ML Studio → Compute → instancja → Start), odczekaj 2–3 minuty i spróbuj ponownie. Sprawdź AUDIT_HOST i AUDIT_PORT." ;;
    *"Connection refused"*)
      cause="Maszyna odpowiada, ale na porcie $AUDIT_PORT nie działa SSH. Maszyna może się jeszcze uruchamiać albo port jest zły."
      fix="Odczekaj 1–2 minuty i spróbuj ponownie. Jeśli błąd się powtarza, sprawdź AUDIT_PORT (Azure ML: zwykle 50000)." ;;
    *"Could not resolve hostname"*|*"Name or service not known"*|*"nodename nor servname"*)
      cause="Nie można odnaleźć adresu '$AUDIT_HOST'."
      fix="Popraw AUDIT_HOST w pliku z danymi (adres IP albo pełna nazwa hosta)." ;;
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
      cause="Klucz hosta maszyny jest inny niż zapamiętany (np. instancja została odtworzona). SSH przerwał połączenie, bo mógłby to być atak typu man-in-the-middle."
      fix="Jeśli wiesz, że maszyna była odtwarzana, usuń stary wpis: ssh-keygen -R \"[$AUDIT_HOST]:$AUDIT_PORT\" i spróbuj ponownie. Jeśli nie, nie łącz się i wyjaśnij przyczynę." ;;
    *"Permission denied"*)
      cause="Maszyna odrzuciła logowanie: zły klucz SSH albo zły użytkownik."
      fix="Sprawdź AUDIT_USER i AUDIT_SSH_KEY w pliku z danymi (klucz musi pasować do maszyny)." ;;
    *"UNPROTECTED PRIVATE KEY"*|*"bad permissions"*)
      cause="Plik klucza ma zbyt szerokie uprawnienia i ssh odmawia jego użycia."
      fix="Ogranicz dostęp do pliku klucza tylko do swojego konta (Windows: Właściwości → Zabezpieczenia)." ;;
    *"No route to host"*|*"Network is unreachable"*)
      cause="Brak trasy sieciowej do maszyny: brak internetu, VPN albo zły adres."
      fix="Sprawdź połączenie z internetem i AUDIT_HOST." ;;
    *"Connection reset"*|*"kex_exchange_identification"*|*"Connection closed"*)
      cause="Połączenie zostało zerwane na starcie. Maszyna może się uruchamiać albo blokować zbyt wiele prób naraz."
      fix="Odczekaj minutę i spróbuj ponownie." ;;
    *)
      cause="Nieznany błąd połączenia SSH."
      fix="Sprawdź szczegóły poniżej oraz adres, port, użytkownika i klucz w pliku z danymi." ;;
  esac
  {
    echo
    echo "BŁĄD POŁĄCZENIA z $AUDIT_USER@$AUDIT_HOST:$AUDIT_PORT"
    echo "  Przyczyna:  $cause"
    echo "  Co zrobić:  $fix"
    echo "  Szczegóły:  $(printf '%s\n' "$out" | grep -v '^\s*$' | tail -1)"
    echo "WYNIK: brak połączenia z maszyną — niczego nie wysłano ani nie zmieniono."
  } >&2
}

step "Połączenie SSH z $AUDIT_USER@$AUDIT_HOST:$AUDIT_PORT"
if ! CONN_OUT=$("${SSH[@]}" 'echo "OK: $(hostname)"' 2>&1 < /dev/null); then
  ssh_diagnose "$CONN_OUT"
  exit 4
fi
echo "$CONN_OUT" | grep '^OK: ' >&2

if [ "$MODE" = uninstall ]; then
  step "Usuwanie środowiska audytu z maszyny"
  upload
  "${SSH[@]}" "bash $TOOL/cleanup.sh \$HOME/.openclaw-audit/footprint.before" || true
  exit 0
fi

step "1. Wymagania na maszynie (tylko odczyt)"
PRE_OUT=$(preflight 2>&1) && PRE_RC=0 || PRE_RC=$?
echo "$PRE_OUT" >&2
[ "$MODE" = check ] && exit $PRE_RC
[ $PRE_RC = 0 ] || [ "$MODE" = audit ] || bad "Uzupełnij brakujące wymagania (BRAK) i uruchom ponownie."

step "2. Wysyłanie skryptów i zdjęcie stanu sprzed audytu"
upload
"${SSH[@]}" "[ -f $ROOT/footprint.before ] && echo 'zdjęcie stanu już istnieje (z pierwszej instalacji)' || { bash $TOOL/preflight.sh snapshot \$HOME/.openclaw-audit/footprint.before && echo \"zapisano: \$(wc -l < \$HOME/.openclaw-audit/footprint.before) ścieżek\"; }" >&2

if [ "$MODE" != audit ]; then
  step "3. Środowisko: Node $NODE_VERSION + OpenClaw $OPENCLAW_VERSION w ~/.openclaw-audit (model: $AUTH_MODE)"
  ENVS="OPENCLAW_VERSION='$OPENCLAW_VERSION' HEALTHCHECK_SHA256='$HEALTHCHECK_SHA256' AUTH_MODE='$AUTH_MODE'"
  ENVS+=" NODE_VERSION='$NODE_VERSION' NODE_SHA256_X64='$NODE_SHA256_X64' NODE_SHA256_ARM64='$NODE_SHA256_ARM64'"
  if [ "$AUTH_MODE" = anthropic-api-key ]; then
    # Klucz idzie strumieniem stdin przez SSH — nie pojawia się w argumentach ani w logach.
    printf '%s\n' "$ANTHROPIC_API_KEY" | "${SSH[@]}" "$ENVS bash $TOOL/install.sh"
  else
    "${SSH[@]}" "$ENVS bash $TOOL/install.sh" < /dev/null
  fi
fi
[ "$MODE" = install ] && { echo "Środowisko gotowe. Usunięcie: bash run-audit.sh -c <plik> --uninstall" >&2; exit 0; }

TS=$(date +%Y%m%d-%H%M%S)
RUN="$ROOT/runs/$TS"
step "4. Audyt na maszynie (kilka minut)"
set +e
"${SSH[@]}" "AGENT_TIMEOUT='$AGENT_TIMEOUT' AUDIT_MODEL='$AUDIT_MODEL' bash $TOOL/audit.sh $RUN" < /dev/null
RC=$?
set -e

LOCAL="$REPORTS_DIR/${AUDIT_HOST}_$TS"
step "5. Pobieranie wyników do $LOCAL"
mkdir -p "$LOCAL"
"${SSH[@]}" "tar -C $RUN -cf - ." | tar -C "$LOCAL" -xf -
printf '%s\n' "$PRE_OUT" > "$LOCAL/preflight.txt"

if [ "$CLEANUP" = yes ]; then
  step "6. Sprzątanie maszyny i kontrola śladów"
  set +e
  "${SSH[@]}" "bash $TOOL/cleanup.sh \$HOME/.openclaw-audit/footprint.before" < /dev/null | tee "$LOCAL/cleanup.txt" >&2
  set -e
else
  step "6. Sprzątanie pominięte (CLEANUP=no) — środowisko zostaje w ~/.openclaw-audit"
  echo "Sprzątanie pominięte (CLEANUP=no). Środowisko audytu zostało w ~/.openclaw-audit; usunięcie: --uninstall." > "$LOCAL/cleanup.txt"
fi

step "7. Składanie raportu"
bash "$HERE/lib/build-report.sh" "$LOCAL" "$AUDIT_HOST" "$OPENCLAW_VERSION" "$AUTH_MODE" "$RC"
echo "Raport (Markdown): $LOCAL/REPORT.md" >&2
echo "Raport (przeglądarka): $LOCAL/REPORT.html" >&2
exit $RC
