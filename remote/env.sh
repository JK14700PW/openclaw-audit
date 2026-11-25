# shellcheck shell=bash
# Wspólne środowisko narzędzia na maszynie audytowanej (dołączane przez `source`).
# Cały ślad narzędzia leży w JEDNYM katalogu: $AUDIT_ROOT. Sprzątanie = usunięcie tego katalogu.
#
#   $AUDIT_ROOT/tool/       skrypty narzędzia
#   $AUDIT_ROOT/rt/node/    prywatny Node.js (przypięta wersja, bez sudo, bez wpływu na systemowy Node)
#   $AUDIT_ROOT/rt/oc/      OpenClaw (npm --prefix)
#   $AUDIT_ROOT/rt/npm-cache/  cache npm (zamiast ~/.npm)
#   $AUDIT_ROOT/rt/home/    OPENCLAW_HOME: konfiguracja, poświadczenia i sesje OpenClaw (zamiast ~/.openclaw)
#   $AUDIT_ROOT/runs/       wyniki przebiegów (usuwane po pobraniu, gdy CLEANUP=yes)

AUDIT_ROOT="$HOME/.openclaw-audit"
RT="$AUDIT_ROOT/rt"
NODE_DIR="$RT/node"
OC_PREFIX="$RT/oc"
OC="$OC_PREFIX/bin/openclaw"

export OPENCLAW_HOME="$RT/home"
export OPENCLAW_STATE_DIR="$OPENCLAW_HOME/.openclaw"
export npm_config_cache="$RT/npm-cache"
export npm_config_update_notifier=false
export npm_config_fund=false
export npm_config_audit=false
# Prywatny Node i OpenClaw mają pierwszeństwo; ~/.local/bin dla `claude` (tryb claude-cli)
export PATH="$NODE_DIR/bin:$OC_PREFIX/bin:$HOME/.local/bin:$PATH"
