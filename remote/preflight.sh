#!/usr/bin/env bash
# Sprawdzenie wymagań na maszynie audytowanej. Tylko odczyt: niczego nie instaluje i nie zmienia.
# Użycie:
#   preflight.sh check              — tabela OK/BRAK/UWAGA z poleceniem naprawy; kod 1, gdy brakuje wymagań blokujących
#   preflight.sh snapshot <plik>    — lista ścieżek w katalogu domowym (do wykrywania śladów po audycie)
# Zmienne: AUTH_MODE (claude-cli | anthropic-api-key)
set -uo pipefail
[ -n "${AUDIT_ROOT:-}" ] || . "$(dirname "$0")/env.sh"   # przy strumieniowaniu przez ssh env.sh jest już doklejony

snapshot() {
  # Same nazwy ścieżek (bez treści), głębokość 3; pomijamy katalog narzędzia i dowiązania (np. zamontowane udziały)
  find "$HOME" -maxdepth 3 -not -path "$AUDIT_ROOT" -not -path "$AUDIT_ROOT/*" \
       -not -path "$HOME/.cache/*" -printf '%P\n' 2>/dev/null | LC_ALL=C sort
}

if [ "${1:-}" = snapshot ]; then snapshot > "${2:?plik}"; exit 0; fi

block=0
row() { # status element szczegóły [naprawa]
  printf '%-6s %-28s %s\n' "$1" "$2" "$3"
  [ -n "${4:-}" ] && printf '%-6s %-28s ↳ %s\n' "" "" "$4"
  [ "$1" = BRAK ] && block=1
  return 0
}
have() { command -v "$1" >/dev/null 2>&1; }

. /etc/os-release 2>/dev/null
row INFO "system" "${PRETTY_NAME:-?}, $(uname -m)"

case "$(uname -m)" in
  x86_64|aarch64) row OK "architektura" "$(uname -m) (obsługiwana przez prywatny Node)" ;;
  *) row BRAK "architektura" "$(uname -m) — brak przypiętego Node dla tej architektury" ;;
esac

if have curl; then row OK "curl" "$(curl --version | head -1 | awk '{print $1, $2}')"
else row BRAK "curl" "potrzebny do pobrania Node" "sudo apt-get install -y curl"; fi

if have tar && have xz; then row OK "tar + xz" "dostępne"
else row BRAK "tar + xz" "potrzebne do rozpakowania Node" "sudo apt-get install -y tar xz-utils"; fi

if have python3; then row OK "python3" "$(python3 --version 2>&1)"
else row BRAK "python3" "potrzebny do analizy settings.json" "sudo apt-get install -y python3"; fi

if sudo -n true 2>/dev/null; then row OK "sudo -n" "dostępne (tylko do odczytu sshd -T i reguł zapory)"
else row UWAGA "sudo -n" "niedostępne — kontrole SSH/zapory dostaną SKIP" "dodaj regułę sudoers tylko dla: sshd -T, ufw status, iptables -S, nft list ruleset, ss"; fi

free_mb=$(df -Pm "$HOME" | awk 'NR==2{print $4}')
[ "${free_mb:-0}" -ge 1500 ] && row OK "miejsce w \$HOME" "${free_mb} MB wolne (potrzeba ~1,5 GB; środowisko zajmuje ~1,2 GB)" \
                             || row BRAK "miejsce w \$HOME" "${free_mb} MB wolne, potrzeba ~1500 MB" "zwolnij miejsce w $HOME"

for url in https://nodejs.org/dist/ https://registry.npmjs.org/openclaw; do
  host=${url#https://}; host=${host%%/*}
  if curl -fsS -o /dev/null --max-time 10 -I "$url" 2>/dev/null; then row OK "sieć: $host" "HTTPS osiągalne"
  else row BRAK "sieć: $host" "brak połączenia HTTPS" "sprawdź proxy / reguły ruchu wychodzącego"; fi
done

if [ -x "$NODE_DIR/bin/node" ]; then row OK "Node (prywatny)" "$("$NODE_DIR/bin/node" --version) w $NODE_DIR"
else row INFO "Node (prywatny)" "brak — zostanie pobrany przy instalacji"; fi
have_sys=$(PATH=/usr/local/bin:/usr/bin:/bin command -v node 2>/dev/null || true)
[ -n "$have_sys" ] && row INFO "Node (systemowy)" "$($have_sys --version) — nie jest używany ani zmieniany"

if [ -x "$OC" ]; then row OK "OpenClaw" "$("$OC" --version 2>/dev/null | awk '{print $2}') w $OC_PREFIX"
else row INFO "OpenClaw" "brak — zostanie zainstalowany przy instalacji"; fi

if [ "${AUTH_MODE:-claude-cli}" = claude-cli ]; then
  if ! have claude; then
    row BRAK "Claude Code" "brak polecenia claude (AUTH_MODE=claude-cli)" "curl -fsSL https://claude.ai/install.sh | bash   albo AUTH_MODE=anthropic-api-key"
  elif claude auth status 2>/dev/null | grep -q '"loggedIn": true'; then
    row OK "Claude Code" "$(claude --version 2>/dev/null | awk '{print $1}'), zalogowany"
  else
    row BRAK "Claude Code" "niezalogowany" "na maszynie: claude  →  /login   albo AUTH_MODE=anthropic-api-key"
  fi
else
  row INFO "dostęp do modelu" "klucz API Anthropic (przekazywany przy instalacji)"
fi

[ -d "$HOME/.openclaw" ] && row INFO "~/.openclaw" "istnieje — narzędzie go nie używa i nie usuwa (stan trzyma w $OPENCLAW_HOME)"
[ -d "$AUDIT_ROOT" ] && row INFO "ślad narzędzia" "$(du -sh "$AUDIT_ROOT" 2>/dev/null | awk '{print $1}') w $AUDIT_ROOT" \
                     || row INFO "ślad narzędzia" "brak (czysta maszyna)"
LEGACY="$HOME/.local/share/openclaw-audit"   # lokalizacja z pierwszej wersji narzędzia
[ -e "$LEGACY" ] && row UWAGA "stara instalacja" "$LEGACY" "usuń: bash run-audit.sh --uninstall"

[ $block = 0 ] && echo "WYNIK: gotowe do audytu" || echo "WYNIK: brakuje wymagań (BRAK) — uzupełnij według wskazówek ↳"
exit $block
