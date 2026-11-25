#!/usr/bin/env bash
# Jeden przebieg audytu na maszynie: dowody deterministyczne + skill healthcheck w OpenClaw.
# Użycie: audit.sh <katalog_wyników>   (zmienne: AGENT_TIMEOUT, AUDIT_MODEL)
set -uo pipefail
OUT="${1:?podaj katalog wyników}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"   # prywatny Node, OpenClaw i OPENCLAW_HOME w katalogu narzędzia
[ -x "$OC" ] || { echo "[audit] BŁĄD: OpenClaw nie jest zainstalowany (uruchom bez --skip-install)" >&2; exit 1; }
mkdir -p "$OUT" && chmod 700 "$OUT"
cd "$OPENCLAW_HOME"

echo "[audit] 1/3 zbieranie dowodów" >&2
bash "$HERE/collect.sh" "$OUT"

echo "[audit] 2/3 skill healthcheck (OpenClaw, lokalnie, bez gateway)" >&2
sed "s|EVIDENCE_DIR|$OUT/evidence|g" "$HERE/prompt.md" > "$OUT/prompt.md"
MODEL_ARGS=(); [ -n "${AUDIT_MODEL:-}" ] && MODEL_ARGS=(--model "$AUDIT_MODEL")
start=$(date +%s)
"$OC" agent --local --agent main --session-id "audit-$(date +%Y%m%d%H%M%S)" \
    --message-file "$OUT/prompt.md" --timeout "${AGENT_TIMEOUT:-900}" "${MODEL_ARGS[@]}" \
    > "$OUT/healthcheck_raw.txt" 2> "$OUT/openclaw_log.txt"
rc=$?
echo "agent_exit=$rc duration_s=$(( $(date +%s) - start ))" > "$OUT/agent_meta.txt"
grep -v '^\[' "$OUT/healthcheck_raw.txt" > "$OUT/healthcheck.md" || true

echo "[audit] 3/3 kontrola: czy agent nie zmienił stanu maszyny" >&2
sudo -n sshd -T 2>/dev/null | sort | diff -q - "$OUT/evidence/sshd_T.txt" >/dev/null \
  && echo "sshd: bez zmian" > "$OUT/post_check.txt" || echo "sshd: ZMIANA!" > "$OUT/post_check.txt"
sudo -n ufw status verbose 2>&1 | diff -q - "$OUT/evidence/ufw.txt" >/dev/null \
  && echo "ufw: bez zmian" >> "$OUT/post_check.txt" || echo "ufw: ZMIANA!" >> "$OUT/post_check.txt"
sha256sum --quiet -c "$OUT/evidence/claude_settings.sha256" >/dev/null 2>&1 \
  && echo "settings.json: bez zmian" >> "$OUT/post_check.txt" || echo "settings.json: ZMIANA!" >> "$OUT/post_check.txt"
cat "$OUT/post_check.txt" >&2
exit $rc
