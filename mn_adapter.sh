#!/usr/bin/env bash
# mn_adapter.sh — adapter version manager: list, activate, compare, rollback.
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
source "$SELF/mn_lib.sh"

REGISTRY="$MN_ADAPTER_REGISTRY"
mkdir -p "$MN_ADAPTER_DIR"

cmd_list() {
  if [ ! -f "$REGISTRY" ]; then echo "no adapter registry yet"; exit 0; fi
  "$MN_VENV/bin/python" - "$REGISTRY" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(f"{'VERSION':<12} {'ACTIVE':<8} {'TRAIN_LOSS':<12} {'EVAL_LOSS':<12} {'TIMESTAMP'}")
for v in r.get("versions", []):
    flag = "=>" if v["name"] == r.get("active") else ""
    print(f"{v['name']:<12} {flag:<8} {v.get('train_loss','?'):<12} {v.get('eval_loss','?'):<12} {v.get('timestamp','')}")
PY
}

cmd_activate() {
  local version="$1"
  [ -z "$version" ] && { echo "usage: $0 activate <version>"; exit 2; }
  if [ ! -f "$REGISTRY" ]; then echo "no registry"; exit 1; fi
  if [ ! -d "$MN_ADAPTER_DIR/$version" ]; then echo "version $version not found"; exit 1; fi
  "$MN_VENV/bin/python" - "$REGISTRY" "$version" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
v = sys.argv[2]
if v not in {x["name"] for x in r["versions"]}:
    print("version not in registry"); sys.exit(1)
r["previous"] = r.get("active")
r["active"] = v
json.dump(r, open(sys.argv[1], "w"), indent=2)
print(f"activated {v} (previous: {r['previous'] or 'none'})")
PY
}

cmd_rollback() {
  if [ ! -f "$REGISTRY" ]; then echo "no registry"; exit 1; fi
  "$MN_VENV/bin/python" - "$REGISTRY" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
prev = r.get("previous")
if not prev:
    print("no previous version to roll back to"); sys.exit(1)
r["active"], r["previous"] = prev, r.get("active")
json.dump(r, open(sys.argv[1], "w"), indent=2)
print(f"rolled back to {r['active']} (was {r['previous']})")
PY
}

cmd_compare() {
  local a="$1" b="$2"
  [ -z "$a" ] || [ -z "$b" ] && { echo "usage: $0 compare <v1> <v2>"; exit 2; }
  "$MN_VENV/bin/python" - "$REGISTRY" "$a" "$b" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
versions = {v["name"]: v for v in r["versions"]}
va, vb = versions.get(sys.argv[2]), versions.get(sys.argv[3])
if not va or not vb:
    print("one or both versions missing"); sys.exit(1)
for k in ["train_loss", "eval_loss", "examples", "steps"]:
    print(f"{k:<15} {va.get(k,'?'):<15} {vb.get(k,'?')}")
PY
}

cmd_gc() {
  local keep="${1:-5}"
  "$MN_VENV/bin/python" - "$REGISTRY" "$keep" "$MN_ADAPTER_DIR" <<'PY'
import json, sys, shutil, os
r = json.load(open(sys.argv[1]))
keep = int(sys.argv[2])
base = sys.argv[3]
names = [v["name"] for v in r["versions"]]
active = r.get("active")
# sort by version index if vN, else by timestamp
def key(n):
    try: return int(n.replace("v","").split(".")[0])
    except: return 0
sorted_names = sorted(names, key=key)
to_keep = set(sorted_names[-keep:])
to_keep.add(active)
for n in names:
    if n not in to_keep and os.path.isdir(f"{base}/{n}"):
        shutil.rmtree(f"{base}/{n}")
        print(f"deleted {n}")
r["versions"] = [v for v in r["versions"] if v["name"] in to_keep]
json.dump(r, open(sys.argv[1], "w"), indent=2)
PY
}

case "${1:-}" in
  list) cmd_list ;;
  activate) cmd_activate "${2:-}" ;;
  rollback) cmd_rollback ;;
  compare) cmd_compare "${2:-}" "${3:-}" ;;
  gc) cmd_gc "${2:-5}" ;;
  *) echo "usage: $0 {list|activate <v>|rollback|compare <v1> <v2>|gc [keep]}"
esac
