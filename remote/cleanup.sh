#!/usr/bin/env bash
# Usuwa z maszyny wszystko, co zainstalowało narzędzie, i sprawdza, czy nie zostały ślady.
# Użycie: cleanup.sh [plik_snapshot_przed]
# Wynik (stdout): raport śladów; kod 0 = czysto, 3 = zostały ślady.
set -uo pipefail
. "$(dirname "$0")/env.sh"
BEFORE="${1:-}"
AFTER_TMP=$(mktemp)

echo "## Sprzątanie"
# 1. Sesje Claude Code utworzone przez OpenClaw w trybie claude-cli (cwd w katalogu narzędzia)
for d in "$HOME"/.claude/projects/*openclaw-audit*; do
  [ -d "$d" ] && rm -rf "$d" && echo "- usunięto sesje Claude: ~/.claude/projects/$(basename "$d")"
done
# 2. Stara lokalizacja z poprzedniej wersji narzędzia
[ -d "$HOME/.local/share/openclaw-audit" ] && rm -rf "$HOME/.local/share/openclaw-audit" \
  && echo "- usunięto starą instalację: ~/.local/share/openclaw-audit"
# 3. Cały katalog narzędzia (Node, OpenClaw, cache npm, stan OpenClaw, skrypty, wyniki)
SIZE=$(du -sh "$AUDIT_ROOT" 2>/dev/null | awk '{print $1}')
# Snapshot "po" liczony przed usunięciem skryptów; katalog narzędzia jest w nim pomijany
[ -n "$BEFORE" ] && [ -f "$BEFORE" ] && cp "$BEFORE" "${AFTER_TMP}.before"
cd "$HOME"
rm -rf "$AUDIT_ROOT"
echo "- usunięto katalog narzędzia: ~/.openclaw-audit (${SIZE:-?})"

echo
echo "## Ślady po audycie"
if [ -f "${AFTER_TMP}.before" ]; then
  find "$HOME" -maxdepth 3 -not -path "$AUDIT_ROOT" -not -path "$AUDIT_ROOT/*" \
       -not -path "$HOME/.cache/*" -printf '%P\n' 2>/dev/null | LC_ALL=C sort > "$AFTER_TMP"
  NEW=$(LC_ALL=C comm -13 "${AFTER_TMP}.before" "$AFTER_TMP")
  # Kopie ~/.claude.json, które Claude CLI (tryb claude-cli) tworzy przy starcie, powstałe w trakcie audytu:
  # są nowe względem zdjęcia stanu, więc na pewno pochodzą z tego przebiegu.
  RM_BK=$(printf '%s\n' "$NEW" | grep -E '^\.claude/backups/\.claude\.json\.backup\.[0-9]+$' || true)
  if [ -n "$RM_BK" ]; then
    while IFS= read -r p; do rm -f "$HOME/$p" && echo "- usunięto kopię ~/.claude.json utworzoną w trakcie audytu: ~/$p"; done <<<"$RM_BK"
    NEW=$(printf '%s\n' "$NEW" | grep -vxF -f <(printf '%s\n' "$RM_BK") || true)
    echo
  fi
  GONE=$(LC_ALL=C comm -23 "${AFTER_TMP}.before" "$AFTER_TMP")
  rm -f "$AFTER_TMP" "${AFTER_TMP}.before"
  if [ -z "$NEW" ]; then
    echo "Brak nowych ścieżek w katalogu domowym (głębokość 3) względem stanu sprzed audytu. ✅"
    [ -n "$GONE" ] && { echo; echo "Ścieżki, które zniknęły (zwykle praca innych procesów):"; echo "$GONE" | sed 's/^/- ~\//'; }
    exit 0
  fi
  echo "Nowe ścieżki względem stanu sprzed audytu (do przejrzenia):"
  echo "$NEW" | sed 's/^/- ~\//'
  exit 3
else
  rm -f "$AFTER_TMP"
  echo "Brak zdjęcia stanu sprzed audytu — nie porównano."
fi
