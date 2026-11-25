#!/usr/bin/env bash
# Deterministyczne zebranie dowodów i reguły kontrolne (bez AI).
# Użycie: collect.sh <katalog_wyników>
# Tylko odczyt. Polecenia uprzywilejowane przez `sudo -n` (bez pytania o hasło);
# gdy sudo niedostępne, kontrola dostaje status SKIP.
set -uo pipefail
OUT="${1:?podaj katalog wyników}"
mkdir -p "$OUT/evidence"
E="$OUT/evidence"
CHECKS="$OUT/checks.tsv"
printf 'id\tobszar\tstatus\tważność\topis\tdowód\n' > "$CHECKS"

S() { sudo -n "$@" 2>/dev/null; }
check() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$CHECKS"; }
HAVE_SUDO=0; sudo -n true 2>/dev/null && HAVE_SUDO=1

# ---------- Kontekst ----------
{
  echo "host: $(hostname)"; echo "date: $(date -Is)"
  . /etc/os-release; echo "os: $PRETTY_NAME"; echo "kernel: $(uname -r)"
  echo "user: $(id)"; echo "sudo_nopasswd: $HAVE_SUDO"
  systemd-detect-virt 2>/dev/null | sed 's/^/virt: /'
  [ -d /mnt/batch ] && echo "platform: Azure ML compute instance (NSG zarządzany przez Azure)"
} > "$E/context.txt"

# ---------- SSH ----------
if [ $HAVE_SUDO = 1 ]; then
  S sshd -T | sort > "$E/sshd_T.txt"
  S sh -c 'grep -vhE "^\s*(#|$)" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf' > "$E/sshd_config.txt" 2>/dev/null
  v() { awk -v k="$1" '$1==k{ $1=""; sub(/^ /,""); print; exit }' "$E/sshd_T.txt"; }
  want() { # id klucz oczekiwana ważność opis
    local got; got=$(v "$2")
    if [ "$got" = "$3" ]; then check "$1" SSH PASS "$4" "$5" "$2=$got"
    else check "$1" SSH FAIL "$4" "$5" "$2=$got (oczekiwano $3)"; fi
  }
  want SSH-01 passwordauthentication no wysoka "Logowanie hasłem wyłączone"
  want SSH-02 permitrootlogin no wysoka "Logowanie na roota wyłączone"
  want SSH-03 kbdinteractiveauthentication no średnia "Keyboard-interactive wyłączone"
  want SSH-04 pubkeyauthentication yes wysoka "Uwierzytelnianie kluczem włączone"
  want SSH-05 x11forwarding no niska "X11 forwarding wyłączony"
  want SSH-06 permitemptypasswords no wysoka "Puste hasła zabronione"
  mat=$(v maxauthtries)
  [ "${mat:-99}" -le 4 ] && check SSH-07 SSH PASS niska "MaxAuthTries <= 4" "maxauthtries=$mat" \
                         || check SSH-07 SSH FAIL niska "MaxAuthTries <= 4" "maxauthtries=$mat"
  ports=$(awk '$1=="port"{print $2}' "$E/sshd_T.txt" | paste -sd, -)
  [ "$(echo "$ports" | tr , '\n' | wc -l)" -le 1 ] \
    && check SSH-08 SSH PASS niska "SSH na jednym porcie" "port=$ports" \
    || check SSH-08 SSH WARN niska "SSH na jednym porcie (mniejsza powierzchnia ataku)" "port=$ports"
  ak=$(v allowusers)$(v allowgroups)
  [ -n "$ak" ] && check SSH-09 SSH PASS średnia "Ograniczenie kont (AllowUsers/AllowGroups)" "$ak" \
               || check SSH-09 SSH WARN średnia "Brak AllowUsers/AllowGroups" "brak dyrektywy"
  tcp=$(v allowtcpforwarding)
  check SSH-10 SSH INFO niska "AllowTcpForwarding (potrzebny do tunelu)" "allowtcpforwarding=$tcp"
else
  check SSH-00 SSH SKIP wysoka "Brak sudo -n — nie odczytano sshd -T" "-"
fi
stat -c '%a %U %n' ~/.ssh ~/.ssh/authorized_keys > "$E/ssh_perms.txt" 2>&1
p=$(stat -c '%a' ~/.ssh/authorized_keys 2>/dev/null)
[[ "$p" =~ ^6?00$ ]] && check SSH-11 SSH PASS średnia "authorized_keys tylko dla właściciela" "mode=$p" \
                      || check SSH-11 SSH FAIL średnia "authorized_keys tylko dla właściciela" "mode=$p"
echo "authorized_keys: $(grep -c . ~/.ssh/authorized_keys 2>/dev/null) kluczy" >> "$E/ssh_perms.txt"
systemctl is-active fail2ban >/dev/null 2>&1 \
  && check SSH-12 SSH PASS średnia "Ochrona przed brute-force (fail2ban)" "active" \
  || check SSH-12 SSH WARN średnia "Ochrona przed brute-force (fail2ban)" "nieaktywny"

# ---------- Firewall ----------
ss -H -tulpn 2>/dev/null > "$E/listening.txt" || ss -H -tuln > "$E/listening.txt"
[ $HAVE_SUDO = 1 ] && S ss -H -tulpn > "$E/listening.txt"
if [ $HAVE_SUDO = 1 ]; then
  S ufw status verbose > "$E/ufw.txt" 2>&1
  S iptables -S > "$E/iptables.txt" 2>&1
  S nft list ruleset > "$E/nft.txt" 2>&1
  if grep -q 'Status: active' "$E/ufw.txt"; then
    check FW-01 Firewall PASS wysoka "Firewall hosta (ufw) aktywny" "$(head -1 "$E/ufw.txt")"
    grep -q 'Default: deny (incoming)' "$E/ufw.txt" \
      && check FW-02 Firewall PASS wysoka "Domyślna polityka: deny incoming" "ufw default" \
      || check FW-02 Firewall FAIL wysoka "Domyślna polityka: deny incoming" "$(grep Default "$E/ufw.txt")"
  else
    pol=$(awk '/^-P INPUT/{print $3}' "$E/iptables.txt")
    if [ "$pol" = "DROP" ]; then
      check FW-01 Firewall PASS wysoka "Firewall hosta aktywny (iptables INPUT DROP)" "INPUT=$pol"
    else
      check FW-01 Firewall FAIL wysoka "Firewall hosta aktywny" "ufw inactive, iptables INPUT=$pol"
    fi
  fi
else
  check FW-00 Firewall SKIP wysoka "Brak sudo -n — nie odczytano reguł" "-"
fi
# Usługi nasłuchujące na wszystkich interfejsach
pub=$(awk '{print $1, $5, $7}' "$E/listening.txt" \
      | grep -E ' (0\.0\.0\.0|\*|\[::\]):[0-9]+' \
      | sed -E 's/users:\(\("([^"]+)".*/\1/' | sort -u)
echo "$pub" > "$E/public_listeners.txt"
n=$(grep -c . "$E/public_listeners.txt")
check FW-03 Firewall INFO średnia "Usługi nasłuchujące na wszystkich interfejsach: $n" "$(echo "$pub" | awk '{print $2"("$3")"}' | paste -sd' ' -)"
grep -qE ':(80|8080|8000|5000|3000|8888) ' <<<"$(echo "$pub" | awk '{print $2" "}')" \
  && check FW-04 Firewall WARN średnia "Port aplikacyjny/HTTP publicznie na interfejsie" "$(echo "$pub" | grep -E ':(80|8080|8000|5000|3000|8888) ' | awk '{print $2"("$3")"}' | paste -sd' ' -)" \
  || check FW-04 Firewall PASS średnia "Brak publicznych portów HTTP/aplikacyjnych" "-"
oc_pub=$(echo "$pub" | grep -E ':18789 ' || true)
[ -z "$oc_pub" ] && check FW-05 Firewall PASS wysoka "OpenClaw gateway nie jest wystawiony publicznie" "18789 brak na 0.0.0.0" \
                 || check FW-05 Firewall FAIL wysoka "OpenClaw gateway wystawiony publicznie" "$oc_pub"
systemctl is-active unattended-upgrades >/dev/null 2>&1 \
  && check UPD-01 Aktualizacje PASS średnia "Automatyczne aktualizacje bezpieczeństwa" "active" \
  || check UPD-01 Aktualizacje WARN średnia "Automatyczne aktualizacje bezpieczeństwa" "nieaktywne; do aktualizacji: $(apt list --upgradable 2>/dev/null | grep -c upgradable)"

# ---------- Uprawnienia konta, na którym działają agenci AI ----------
# Grupy dające w praktyce uprawnienia roota: sudo bez hasła, docker (montowanie /), lxd (kontener uprzywilejowany)
priv=()
[ $HAVE_SUDO = 1 ] && priv+=("sudo NOPASSWD")
for g in docker lxd; do id -nG | tr ' ' '\n' | grep -qx "$g" && priv+=("grupa $g"); done
[ ${#priv[@]} -eq 0 ] \
  && check PRIV-01 Konto PASS wysoka "Konto agenta bez ścieżek do roota" "$(id -un)" \
  || check PRIV-01 Konto WARN wysoka "Konto agenta ma ścieżki do roota (agent AI = root)" "$(id -un): $(IFS=,; echo "${priv[*]}")"

# ---------- Claude Code: .claude/settings.json ----------
CL="$E/claude_settings"
mkdir -p "$CL"
mapfile -t FILES < <( { ls -1 "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" /etc/claude-code/managed-settings.json 2>/dev/null
                        find "$HOME" -maxdepth 4 -path '*/.claude/settings*.json' -not -path "$HOME/.claude/*" 2>/dev/null; } | sort -u)
[ ${#FILES[@]} -gt 0 ] && sha256sum "${FILES[@]}" > "$E/claude_settings.sha256"
if [ ${#FILES[@]} -eq 0 ]; then
  check CC-00 ClaudeCode FAIL wysoka "Brak jakiegokolwiek pliku settings.json" "-"
fi
for f in "${FILES[@]}"; do
  tag=$(echo "$f" | sed "s|^$HOME|home|; s|^/||; s|/|_|g")
  # Kopia z zamaskowanymi wartościami env (mogą zawierać sekrety)
  python3 - "$f" > "$CL/$tag" <<'PY' 2>/dev/null || cp "$f" "$CL/$tag"
import json,sys
d=json.load(open(sys.argv[1]))
if isinstance(d.get("env"),dict):
    d["env"]={k:"***" for k in d["env"]}
print(json.dumps(d,indent=2,ensure_ascii=False))
PY
  short=$(echo "$f" | sed "s|$HOME|~|")
  mode=$(stat -c '%a' "$f")
  (( 8#$mode & 8#022 )) \
    && check CC-01 ClaudeCode FAIL średnia "settings.json zapisywalny dla grupy/innych" "$short mode=$mode" \
    || check CC-01 ClaudeCode PASS średnia "settings.json bez zapisu dla grupy/innych" "$short mode=$mode"
  python3 - "$f" "$short" >> "$CHECKS" <<'PY'
import json,sys
f,short=sys.argv[1],sys.argv[2]
def out(i,st,sev,desc,ev): print(f"{i}\tClaudeCode\t{st}\t{sev}\t{desc}\t{short}: {ev}")
try: d=json.load(open(f))
except Exception as e: out("CC-02","FAIL","wysoka","Plik nie jest poprawnym JSON",str(e)); sys.exit()
p=d.get("permissions") or {}
deny,ask,allow=p.get("deny",[]),p.get("ask",[]),p.get("allow",[])
mode=p.get("defaultMode","(domyślny)")
out("CC-02","PASS" if (deny or ask) else "FAIL","wysoka","Zdefiniowane reguły deny/ask",f"deny={len(deny)} ask={len(ask)} allow={len(allow)}")
out("CC-03","FAIL" if mode=="bypassPermissions" else "PASS","wysoka","defaultMode różny od bypassPermissions",f"defaultMode={mode}")
risky=[a for a in allow if a in("Bash","Bash(*)","Bash(*:*)","Write","Edit","WebFetch") or a.startswith(("Bash(sudo","Bash(rm","Bash(curl","Bash(git push"))]
out("CC-04","FAIL" if risky else "PASS","wysoka","Brak zbyt szerokich reguł allow",", ".join(risky) or "-")
need={"rm":any("rm" in x for x in deny),".env":any(".env" in x for x in deny)}
miss=[k for k,v in need.items() if not v]
out("CC-05","WARN" if miss else "PASS","średnia","Deny dla rm i odczytu .env",("brak: "+", ".join(miss)) if miss else "jest")
hooks=d.get("hooks",{}).get("PreToolUse",[])
out("CC-06","PASS" if hooks else "WARN","średnia","Hook PreToolUse (twarda blokada)",f"{len(hooks)} hook(i)")
env=d.get("env",{})
sec=[k for k in env if any(s in k.upper() for s in("KEY","TOKEN","SECRET","PASSWORD"))]
out("CC-07","FAIL" if sec else "PASS","wysoka","Brak sekretów w sekcji env",", ".join(sec) or "-")
dis=p.get("disableBypassPermissionsMode", d.get("disableBypassPermissionsMode"))
out("CC-08","PASS" if dis=="disable" else "WARN","niska","Zablokowany tryb bypassPermissions",f"permissions.disableBypassPermissionsMode={dis}")
PY
done
ls -l "$HOME/.claude/.credentials.json" "$HOME/.claude.json" 2>/dev/null > "$E/claude_cred_perms.txt"

# Podsumowanie
awk -F'\t' 'NR>1{c[$3]++} END{for(k in c) printf "%s=%d ", k, c[k]; print ""}' "$CHECKS" > "$OUT/checks_summary.txt"
cat "$OUT/checks_summary.txt" >&2
