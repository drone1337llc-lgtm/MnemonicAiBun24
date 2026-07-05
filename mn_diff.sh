#!/usr/bin/env bash
# mn_diff.sh — diff mn_env.json across your fleet.
# Requires: ssh-key based access to each box (no password prompts).
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
source "$SELF/mn_lib.sh"

if [ -z "$MN_FLEET" ]; then
  if [ -f "$MN_ENV_FILE" ]; then
    BOX=$(hostname -s)
    BOXES=("$BOX")
    _mn_log "no MN_FLEET set — diffing local mn_env.json against itself (sanity check)"
  else
    _mn_err "no MN_FLEET and no local $MN_ENV_FILE"
    exit 1
  fi
else
  IFS=',' read -ra BOXES <<<"$MN_FLEET"
fi

[ "${#BOXES[@]}" -ge 1 ] || { _mn_err "no boxes to diff"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------- fetch ----------
for box in "${BOXES[@]}"; do
  target="$box"
  [[ "$target" == *@* ]] || target="${USER:-surge}@${target}"
  echo ">> fetching $target"
  if [[ "$target" == *"@"* ]]; then
    if ! scp -o ConnectTimeout=5 -o BatchMode=yes \
      "$target:$(basename "$MN_REPO")/mn_env.json" \
      "$TMP/$(echo "$target" | tr '@' '_').json" 2>/dev/null; then
      _mn_err "could not ssh to $target — set up ssh keys first"
      continue
    fi
  elif [ -f "$MN_ENV_FILE" ]; then
    cp "$MN_ENV_FILE" "$TMP/$(echo "$target" | tr '@' '_').json"
  else
    _mn_err "no local mn_env.json for $target"
    continue
  fi
done

# ---------- diff ----------
echo
_mn_log "diffing across $(ls "$TMP" | wc -l) box(es)"
for key in torch cuda_runtime cudnn transformers peft accelerate bitsandbytes safetensors sentencepiece python gpu_stack; do
  echo
  echo "--- $key ---"
  for f in "$TMP"/*.json; do
    [ -f "$f" ] || continue
    box=$(basename "$f" .json)
    val=$(grep "\"$key\"" "$f" | head -1 | sed -E 's/.*: *"?([^",}]+)"?[,} ]*.*/\1/')
    printf "  %-30s %s\n" "$box" "${val:-MISSING}"
  done
done

# ---------- GPU cross-check ----------
echo
echo "--- GPUs (per-box) ---"
for f in "$TMP"/*.json; do
  [ -f "$f" ] || continue
  box=$(basename "$f" .json)
  echo "  $box:"
  "$MN_VENV/bin/python" - "$f" <<'PY' 2>/dev/null || echo "    (could not parse)"
import json, sys
e = json.load(open(sys.argv[1]))
for g in e.get("gpus", []):
    print(f"    cuda:{g['index']}  {g['name']}  ({g.get('pcie_link','')})")
PY
done

# ---------- alerts ----------
DRIFT=""
for key in torch transformers peft; do
  vals=$(for f in "$TMP"/*.json; do
          [ -f "$f" ] && grep "\"$key\"" "$f" | sed -E 's/.*"([^",}]+)".*/\1/'
        done | sort -u | wc -l)
  if [ "$vals" -gt 1 ]; then DRIFT="$DRIFT $key"; fi
done
if [ -n "$DRIFT" ]; then
  mn_alert "mn-diff DRIFT" "mismatched versions:$DRIFT"
  _mn_err "DRIFT detected in:$DRIFT — boxes will not bake interchangeable adapters"
  exit 2
fi
_mn_ok  "all boxes report identical $key — fleet is consistent"
