#!/usr/bin/env bash
# Nightly MikroTik config export into git: one file per router, a commit only when something changed.
# Like RANCID/Oxidized, but 60 lines of Bash.
#
#   routers.txt:  name  host  [port]
#   env: BACKUP_REPO (git working copy), SSH_USER (default: backup), SSH_KEY (default: ~/.ssh/id_ed25519)
set -Eeuo pipefail

ROUTERS="${ROUTERS:-$(dirname "$0")/routers.txt}"
BACKUP_REPO="${BACKUP_REPO:?BACKUP_REPO is required}"
SSH_USER="${SSH_USER:-backup}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
failed=()

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

export_one() {  # name host port
  local name="$1" host="$2" port="${3:-22}" out="$BACKUP_REPO/$1.rsc"
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
      -i "$SSH_KEY" -p "$port" "$SSH_USER@$host" '/export show-sensitive=no terse' > "$out.tmp" || return 1   # set -e is off inside an if-condition
  # RouterOS puts a timestamp in the first line: drop it, or every run is a diff
  sed -i -E '1{/^# [0-9]{4}-[0-9]{2}-[0-9]{2}|^# [a-z]{3}\/[0-9]{2}\/[0-9]{4}/d}' "$out.tmp" || return 1
  tr -d '\r' < "$out.tmp" > "$out" || return 1
  rm -f "$out.tmp"
}

while read -r name host port; do
  [[ -z "${name:-}" || "$name" == \#* ]] && continue
  if export_one "$name" "$host" "${port:-22}"; then
    log "ok   $name"
  else
    log "FAIL $name"; failed+=("$name"); rm -f "$BACKUP_REPO/$name.rsc.tmp"
  fi
done < "$ROUTERS"

cd "$BACKUP_REPO"
git add -A
if ! git diff --cached --quiet; then
  git commit -q -m "config backup $(date -u +%F): $(git diff --cached --name-only | tr '\n' ' ')"
  git push -q
  log "changes committed"
else
  log "no changes"
fi

if (( ${#failed[@]} )); then
  log "failed: ${failed[*]}"; exit 1
fi
