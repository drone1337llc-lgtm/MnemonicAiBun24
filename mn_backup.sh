#!/usr/bin/env bash
# mn_backup.sh — snapshot mnemonicai_data/, rotate, optionally push offsite.
# Cron: 17 3 * * *  /home/surge/MnemonicAi/mn_backup.sh >> /home/surge/MnemonicAi/mnemonicai_data/logs/backup.log 2>&1
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
source "$SELF/mn_lib.sh"

_mn_log "backup starting (data=$MN_DATA)"

# ---------- preflight ----------
[ -d "$MN_DATA" ] || { _mn_err "data dir missing: $MN_DATA"; exit 1; }
_mn_check_deps || { _mn_err "required dependencies missing — aborting"; exit 1; }

# ---------- consistent SQLite snapshot ----------
SNAP_DIR="$MN_DATA/.snapshot.$$"
mkdir -p "$SNAP_DIR"
trap 'rm -rf "$SNAP_DIR"' EXIT

if [ -f "$MN_PID" ] && kill -0 "$(cat "$MN_PID")" 2>/dev/null; then
  _mn_log "server is running — taking SQLite snapshot via VACUUM INTO"
  "$MN_VENV/bin/python" - "$MN_DATA/memory.db" "$SNAP_DIR/memory.db" <<'PY' || true
import sys, sqlite3
src, dst = sys.argv[1], sys.argv[2]
con = sqlite3.connect(src)
with con:
    con.execute(f"VACUUM INTO '{dst}'")
con.close()
print("sqlite snapshot ok")
PY
  rsync -a --exclude='memory.db' --exclude='.snapshot' "$MN_DATA/" "$SNAP_DIR/"
else
  _mn_log "server not running — copying data dir directly"
  rsync -a --exclude='.snapshot' "$MN_DATA/" "$SNAP_DIR/"
fi

# ---------- tarball ----------
TS=$(date -u +%Y%m%dT%H%M%SZ)
HOST=$(hostname -s)
BASE="mn_${HOST}_${TS}"
TAR="${MN_BACKUP_LOCAL}/${BASE}.tar.zst"
mkdir -p "$MN_BACKUP_LOCAL"
_mn_log "creating tarball: $TAR"
tar --zstd --use-compress-program="zstd -T${MN_BACKUP_THREADS} -19" \
    -C "$SNAP_DIR" -cf "$TAR" .
sha256sum "$TAR" | tee "${TAR}.sha256" >/dev/null
SIZE=$(du -h "$TAR" | awk '{print $1}')
_mn_ok  "tarball written ($SIZE)"

# ---------- offsite copy ----------
if [ -n "$MN_BACKUP_OFFSITE" ] && [ -d "$MN_BACKUP_OFFSITE" ]; then
  _mn_log "copying to offsite: $MN_BACKUP_OFFSITE"
  mkdir -p "$MN_BACKUP_OFFSITE"
  cp -a "$TAR" "$TAR.sha256" "$MN_BACKUP_OFFSITE/"
  _mn_ok  "offsite copy done"
elif [ -n "$MN_BACKUP_OFFSITE" ]; then
  _mn_err "offsite target $MN_BACKUP_OFFSITE not mounted — only local backup kept"
  mn_alert "mn-backup OFFSITE-FAIL" "offsite $MN_BACKUP_OFFSITE not present; local backup at $TAR"
fi

# ---------- retention ----------
_mn_log "pruning local backups (keep daily=${MN_BACKUP_KEEP_DAILY} weekly=${MN_BACKUP_KEEP_WEEKLY} monthly=${MN_BACKUP_KEEP_MONTHLY})"

DAILY=$(ls -1t "$MN_BACKUP_LOCAL"/mn_${HOST}_*.tar.zst 2>/dev/null | tail -n +$((MN_BACKUP_KEEP_DAILY + 1)))
[ -n "$DAILY" ] && rm -f $DAILY && _mn_log "deleted $(echo "$DAILY" | wc -l) old daily tarballs"

find "$MN_BACKUP_LOCAL" -name "mn_${HOST}_*.tar.zst" -mtime +7 -mtime -30 \
  -printf "%T@ %p\n" 2>/dev/null | sort -n | head -n -${MN_BACKUP_KEEP_WEEKLY} \
  | awk '{print $2}' | xargs -r rm -f

find "$MN_BACKUP_LOCAL" -name "mn_${HOST}_*.tar.zst" -mtime +30 \
  -printf "%T@ %p\n" 2>/dev/null | sort -n | head -n -${MN_BACKUP_KEEP_MONTHLY} \
  | awk '{print $2}' | xargs -r rm -f

# ---------- done ----------
REMAINING=$(ls -1 "$MN_BACKUP_LOCAL"/mn_${HOST}_*.tar.zst 2>/dev/null | wc -l)
_mn_ok  "backup complete — $REMAINING tarball(s) retained locally"
