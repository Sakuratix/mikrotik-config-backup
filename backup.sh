#!/usr/bin/env bash
# Nightly MikroTik config export into git: one file per router, a commit only when something changed.
# Like RANCID/Oxidized, but 60 lines of Bash.
#
#   routers.txt:  name  host  [port]
#   env: BACKUP_REPO (git working copy), SSH_USER (default: backup), SSH_KEY (default: ~/.ssh/id_ed25519)
#        PARALLEL (default: 8) routers exported at the same time
#        PRUNE_REMOVED=1 delete <name>.rsc of routers no longer in routers.txt (git keeps the history)
#        METRICS_DIR (default: /var/lib/node_exporter/textfile) Prometheus textfile metrics, skipped if missing
set -Eeuo pipefail

ROUTERS="${ROUTERS:-$(dirname "$0")/routers.txt}"
BACKUP_REPO="${BACKUP_REPO:?BACKUP_REPO is required}"
SSH_USER="${SSH_USER:-backup}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
PARALLEL="${PARALLEL:-8}"
METRICS_DIR="${METRICS_DIR:-/var/lib/node_exporter/textfile}"
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

# Values that must never reach git. RouterOS hides them with show-sensitive=no (v7)
# or hide-sensitive (v6), but a wrong flag or user policy would leak them silently.
SECRET_RE='(^|[[:space:]])(password|secret|private-key|passphrase|authentication-key|pre-shared-key|wpa-pre-shared-key|wpa2-pre-shared-key|psk)=("[^"]+"|[^"[:space:]][^[:space:]]*)'

ros() {  # host port command
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
      -i "$SSH_KEY" -p "$2" "$SSH_USER@$1" "$3"
}

export_one() {  # name host port
  local name="$1" host="$2" port="${3:-22}" out="$BACKUP_REPO/$1.rsc"
  ros "$host" "$port" '/export show-sensitive=no terse' > "$out.tmp" || return 1   # set -e is off inside an if-condition
  # RouterOS 6 doesn't know show-sensitive and answers with a syntax error; its flag is hide-sensitive
  if grep -qE '^(expected end of command|syntax error|bad command name)' "$out.tmp"; then
    ros "$host" "$port" '/export hide-sensitive terse' > "$out.tmp" || return 1
  fi
  if grep -qE '^(expected end of command|syntax error|bad command name|failure:)' "$out.tmp"; then
    log "$name: RouterOS rejected the export command: $(head -1 "$out.tmp")"; return 1
  fi
  if grep -qiE "$SECRET_RE" "$out.tmp"; then
    log "$name: export contains secret values, refusing to write it (check the export flags and the user's policy)"
    grep -oiE "$SECRET_RE" "$out.tmp" | sed -E 's/=.*/=<redacted>/' | sort -u | head -5 >&2
    return 1
  fi
  # RouterOS puts a timestamp in the first line: drop it, or every run is a diff
  sed -i -E '1{/^# [0-9]{4}-[0-9]{2}-[0-9]{2}|^# [a-z]{3}\/[0-9]{2}\/[0-9]{4}/d}' "$out.tmp" || return 1
  tr -d '\r' < "$out.tmp" > "$out" || return 1
  rm -f "$out.tmp"
}

run_one() {  # runs in the background; leaves a marker file with the result
  if export_one "$@"; then
    log "ok   $1"; : > "$state/ok.$1"
  else
    log "FAIL $1"; rm -f "$BACKUP_REPO/$1.rsc.tmp"; : > "$state/fail.$1"
  fi
}

# One slow or dead site used to hold up the whole run for its SSH timeout;
# now up to $PARALLEL routers are exported at once.
running=0
listed=()
while read -r name host port; do
  [[ -z "${name:-}" || "$name" == \#* ]] && continue
  listed+=("$name")
  run_one "$name" "$host" "${port:-22}" &
  if (( ++running >= PARALLEL )); then
    wait -n; running=$((running - 1))
  fi
done < "$ROUTERS"
wait

failed=()
for f in "$state"/fail.*; do [[ -e $f ]] && failed+=("${f##*/fail.}"); done

write_metrics() {  # one series per router, for node_exporter's textfile collector
  [[ -d "$METRICS_DIR" ]] || return 0
  local out="$METRICS_DIR/mikrotik_backup.prom" f r now
  now="$(date +%s)"
  {
    echo "# HELP mikrotik_backup_success Last export of this router succeeded (1) or failed (0)."
    echo "# TYPE mikrotik_backup_success gauge"
    for f in "$state"/ok.* "$state"/fail.*; do
      [[ -e $f ]] || continue
      r="${f##*/}"
      echo "mikrotik_backup_success{router=\"${r#*.}\"} $([[ $r == ok.* ]] && echo 1 || echo 0)"
    done
    echo "# HELP mikrotik_backup_last_run_timestamp_seconds When the backup last ran."
    echo "# TYPE mikrotik_backup_last_run_timestamp_seconds gauge"
    echo "mikrotik_backup_last_run_timestamp_seconds $now"
    echo "# HELP mikrotik_backup_changed_routers Routers whose config changed in the last run."
    echo "# TYPE mikrotik_backup_changed_routers gauge"
    echo "mikrotik_backup_changed_routers ${changed:-0}"
  } > "$out.$$" && mv "$out.$$" "$out"
}

# Commit body: per router, lines added/removed and which RouterOS menus changed,
# so `git log` answers "what changed on core-01 last night" without opening diffs.
summary() {
  local f
  git diff --cached --name-only | while read -r f; do
    git diff --cached --numstat -- "$f" | awk -v f="$f" '{printf "%s: +%s -%s", f, $1, $2}'
    git diff --cached -U0 -- "$f" | awk '
      /^[+-]\// && !/^(\+\+\+|---) / {
        path = ""
        for (i = 1; i <= NF; i++) {
          w = (i == 1) ? substr($i, 2) : $i
          if (w ~ /=/ || w ~ /^(add|set|remove|enable|disable)$/) break
          path = path (path == "" ? "" : " ") w
        }
        if (!(path in seen)) { seen[path] = 1; list = list (list == "" ? "" : ", ") path }
      }
      END { if (list != "") printf " (%s)", list }'
    echo
  done
}

cd "$BACKUP_REPO"
# A decommissioned router's last config would otherwise sit in the tree forever,
# looking current. Deleting it is safe: `git log --all -- old.rsc` still has it.
if [[ "${PRUNE_REMOVED:-0}" == 1 ]]; then
  for f in *.rsc; do
    [[ -e $f ]] || continue
    if [[ " ${listed[*]} " != *" ${f%.rsc} "* ]]; then
      log "removed from routers.txt, deleting $f"; git rm -q -- "$f"
    fi
  done
fi
git add -A
if ! git diff --cached --quiet; then
  changed="$(git diff --cached --name-only | grep -c '\.rsc$' || true)"
  git commit -q -m "config backup $(date -u +%F): $(git diff --cached --name-only | tr '\n' ' ')" -m "$(summary)"
  git push -q
  log "changes committed"
else
  log "no changes"
fi

write_metrics

if (( ${#failed[@]} )); then
  log "failed: ${failed[*]}"; exit 1
fi
