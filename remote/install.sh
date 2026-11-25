#!/usr/bin/env bash
# Idempotentna instalacja środowiska audytu w katalogu narzędzia (bez sudo, bez zmian w systemie).
# Wejście (zmienne): OPENCLAW_VERSION, HEALTHCHECK_SHA256, AUTH_MODE,
#                    NODE_VERSION, NODE_SHA256_X64, NODE_SHA256_ARM64
# Klucz API (tylko AUTH_MODE=anthropic-api-key) przychodzi na stdin — nigdy w argumentach.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"

: "${OPENCLAW_VERSION:?}" "${HEALTHCHECK_SHA256:?}" "${AUTH_MODE:?}"
: "${NODE_VERSION:?}" "${NODE_SHA256_X64:?}" "${NODE_SHA256_ARM64:?}"

log() { printf '[install] %s\n' "$*" >&2; }
die() { printf '[install] BŁĄD: %s\n' "$*" >&2; exit 1; }
oc()  { "$OC" "$@" 2> >(grep -v -e 'SECURITY WARNING' -e DeprecationWarning -e 'trace-deprecation' >&2); }

mkdir -p "$RT" && chmod 700 "$AUDIT_ROOT" "$RT"

# 0. Wymagania (tylko odczyt)
if ! AUTH_MODE="$AUTH_MODE" bash "$HERE/preflight.sh" check >&2; then
  die "nie spełniono wymagań — patrz tabela powyżej"
fi

# 1. Prywatny Node.js (przypięta wersja, weryfikacja SHA-256)
case "$(uname -m)" in
  x86_64)  ARCH=x64;   WANT_SHA=$NODE_SHA256_X64 ;;
  aarch64) ARCH=arm64; WANT_SHA=$NODE_SHA256_ARM64 ;;
  *) die "nieobsługiwana architektura $(uname -m)" ;;
esac
CUR_NODE=$([ -x "$NODE_DIR/bin/node" ] && "$NODE_DIR/bin/node" --version || true)
if [ "$CUR_NODE" = "v$NODE_VERSION" ]; then
  log "Node v$NODE_VERSION już jest"
else
  TB="node-v$NODE_VERSION-linux-$ARCH.tar.xz"
  log "Pobieram $TB"
  TMP=$(mktemp -d "$RT/dl.XXXXXX")
  curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/$TB" "https://nodejs.org/dist/v$NODE_VERSION/$TB"
  GOT=$(sha256sum "$TMP/$TB" | awk '{print $1}')
  [ "$GOT" = "$WANT_SHA" ] || { rm -rf "$TMP"; die "SHA-256 Node się nie zgadza ($GOT) — przerwano"; }
  rm -rf "$NODE_DIR" && mkdir -p "$NODE_DIR"
  tar -xJf "$TMP/$TB" -C "$NODE_DIR" --strip-components=1
  rm -rf "$TMP"
  log "Node $("$NODE_DIR/bin/node" --version) zainstalowany w $NODE_DIR (SHA-256 zgodny)"
fi

# 2. OpenClaw w przypiętej wersji; --ignore-scripts: żadne skrypty instalacyjne paczek się nie wykonują
CUR=$([ -x "$OC" ] && "$OC" --version 2>/dev/null | awk '{print $2}' || true)
if [ "$CUR" = "$OPENCLAW_VERSION" ]; then
  log "OpenClaw $CUR już jest"
else
  log "Instaluję openclaw@$OPENCLAW_VERSION (było: ${CUR:-brak})"
  (cd "$RT" && npm install -g --prefix "$OC_PREFIX" --ignore-scripts --loglevel=error \
      "openclaw@$OPENCLAW_VERSION") >&2
fi

# 3. Kontrola integralności ocenionego skilla
SKILL="$OC_PREFIX/lib/node_modules/openclaw/skills/healthcheck/SKILL.md"
[ -f "$SKILL" ] || die "brak skilla healthcheck w paczce"
GOT=$(sha256sum "$SKILL" | awk '{print $1}')
[ "$GOT" = "$HEALTHCHECK_SHA256" ] || die "SKILL.md ma inny SHA-256 ($GOT) niż oceniony — przejrzyj zmiany i zaktualizuj HEALTHCHECK_SHA256"
log "healthcheck/SKILL.md zgodny z ocenioną wersją"

# 4. Konfiguracja OpenClaw (stan w $OPENCLAW_HOME, nie w ~/.openclaw)
COMMON=(--non-interactive --accept-risk --mode local --gateway-bind loopback
        --skip-daemon --skip-channels --skip-search --skip-hooks --skip-ui
        --skip-health --suppress-gateway-token-output --json)
mkdir -p "$OPENCLAW_HOME" && chmod 700 "$OPENCLAW_HOME"
CONFIGURED=$(cat "$RT/auth_mode" 2>/dev/null || true)
case "$AUTH_MODE" in
  claude-cli)
    [ "$CONFIGURED" = claude-cli ] || { log "Konfiguracja: model przez Claude CLI"; oc onboard "${COMMON[@]}" --auth-choice anthropic-cli >/dev/null; }
    ;;
  anthropic-api-key)
    IFS= read -r KEY || true
    [ -n "${KEY:-}" ] || die "AUTH_MODE=anthropic-api-key, ale nie przekazano klucza na stdin"
    log "Konfiguracja: model przez klucz API (zapis w $OPENCLAW_STATE_DIR, prawa 600)"
    # Klucz przez zmienną środowiskową (OpenClaw: envVar ANTHROPIC_API_KEY), NIE przez --anthropic-api-key:
    # argumenty procesu widzi każdy użytkownik przez `ps`, środowisko procesu tylko jego właściciel i root.
    ANTHROPIC_API_KEY="$KEY" oc onboard "${COMMON[@]}" --auth-choice apiKey >/dev/null
    unset KEY
    ;;
  *) die "nieznany AUTH_MODE=$AUTH_MODE" ;;
esac
echo "$AUTH_MODE" > "$RT/auth_mode"

# 5. Twarde ustawienia OpenClaw na czas audytu
oc config set gateway.bind loopback >/dev/null 2>&1 || true
oc config set update.checkOnStart false --strict-json >/dev/null 2>&1 || true
oc config set browser.extensionRelay.allowLegacyAuth false --strict-json >/dev/null 2>&1 || true
chmod -R go-rwx "$OPENCLAW_HOME" 2>/dev/null || true

oc skills info healthcheck | grep -q 'Ready' || die "skill healthcheck nie jest gotowy"
log "Gotowe: $("$OC" --version 2>/dev/null | head -1), Node $(node --version), ślad: $(du -sh "$AUDIT_ROOT" | awk '{print $1}')"
