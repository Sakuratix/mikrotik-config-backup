#!/usr/bin/env bash
# Tests for backup.sh with a fake `ssh` on PATH and throwaway git repos.
# No routers needed: each fake host prints a canned RouterOS export.
set -Eeuo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; pass=$((pass + 1)); }

# --- fake ssh: the export for host H is read from $FAKE/H.rsc, missing file = unreachable
mkdir -p "$work/bin" "$work/fake"
cat > "$work/bin/ssh" <<'SSH'
#!/usr/bin/env bash
host=""; for a in "$@"; do [[ $a == *@* ]] && host="${a#*@}"; done
f="$FAKE/$host.rsc"
[[ -f $f ]] || { echo "ssh: connect to host $host port 22: Connection timed out" >&2; exit 255; }
[[ -n "${SSH_DELAY:-}" ]] && sleep "$SSH_DELAY"
cat "$f"
SSH
chmod +x "$work/bin/ssh"
export PATH="$work/bin:$PATH" FAKE="$work/fake"

export_v7() { printf '# %s 03:15:02 by RouterOS 7.16.1\r\n# software id = AB12-CD34\r\n/ip address add address=%s/24 interface=ether1\r\n' "$1" "$2"; }
export_v6() { printf '# %s 03:15:02 by RouterOS 6.49.10\n/ip address add address=%s/24 interface=ether1\n' "$1" "$2"; }

# --- a backup repo with a bare "remote" so git push works
git init -q --bare "$work/remote.git"
git clone -q "$work/remote.git" "$work/repo" 2>/dev/null
git -C "$work/repo" config user.email test@example.com
git -C "$work/repo" config user.name test
git -C "$work/repo" commit -q --allow-empty -m init
git -C "$work/repo" push -q origin HEAD 2>/dev/null
export BACKUP_REPO="$work/repo" SSH_KEY=/dev/null ROUTERS="$work/routers.txt"
commits() { git -C "$work/repo" rev-list --count HEAD; }
run() { "$root/backup.sh" 2>"$work/log"; }

cat > "$ROUTERS" <<'R'
# name     host
core-01    10.0.0.1
club-02    10.0.0.2  2222

R
export_v7 2026-11-10 192.168.1.1 > "$FAKE/10.0.0.1.rsc"
export_v6 nov/10/2026 192.168.2.1 > "$FAKE/10.0.0.2.rsc"

run || fail "first run failed: $(cat "$work/log")"
[[ $(commits) == 2 ]] || fail "expected one backup commit"
head -1 "$work/repo/core-01.rsc" | grep -q "software id" || fail "v7 timestamp line not stripped"
grep -q 'by RouterOS' "$work/repo/club-02.rsc" && fail "v6 timestamp line not stripped"
grep -q $'\r' "$work/repo/core-01.rsc" && fail "CRLF not converted"
[[ $(git -C "$work/remote.git" rev-list --count HEAD) == 2 ]] || fail "not pushed"
ok "exports both routers, strips timestamps and CRLF, commits and pushes"

# same config, new timestamp: must not create a commit
export_v7 2026-11-11 192.168.1.1 > "$FAKE/10.0.0.1.rsc"
export_v6 nov/11/2026 192.168.2.1 > "$FAKE/10.0.0.2.rsc"
run || fail "second run failed"
[[ $(commits) == 2 ]] || fail "a timestamp-only change produced a commit"
grep -q "no changes" "$work/log" || fail "expected 'no changes'"
ok "timestamp-only differences don't produce commits"

# a real change: one commit naming only that router
export_v7 2026-11-12 192.168.100.1 > "$FAKE/10.0.0.1.rsc"
run || fail "third run failed"
[[ $(commits) == 3 ]] || fail "real change not committed"
msg=$(git -C "$work/repo" log -1 --format=%s)
[[ $msg == *core-01.rsc* && $msg != *club-02* ]] || fail "commit message: $msg"
ok "a real change is committed with the router name in the message"

# unreachable router: exit 1, others still backed up, last good file kept
rm "$FAKE/10.0.0.2.rsc"
export_v7 2026-11-13 192.168.200.1 > "$FAKE/10.0.0.1.rsc"
if run; then fail "exit 0 with an unreachable router"; fi
grep -q "FAIL club-02" "$work/log" || fail "failure not logged"
grep -q "192.168.200.1" "$work/repo/core-01.rsc" || fail "healthy router not backed up"
grep -q "192.168.2.1" "$work/repo/club-02.rsc" || fail "last good config of the failed router was lost"
[[ ! -e "$work/repo/club-02.rsc.tmp" ]] || fail "temp file left behind"
ok "an unreachable router fails the run but keeps its last good config"

echo "$pass tests passed"
