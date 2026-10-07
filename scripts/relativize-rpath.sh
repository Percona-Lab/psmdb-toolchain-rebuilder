#!/usr/bin/env bash
#
# Rewrites absolute rpaths to $ORIGIN-relative ones.
# Bazel unpacks anywhere; upstream gdb is relative.
# Entries outside the tree are dropped.
#
# Usage: relativize-rpath.sh <tree> <old-root>

set -euo pipefail

tree="$(realpath "${1:?tree}")"
old="${2:?old root}"; old="${old%/}"
command -v patchelf >/dev/null || { echo "[rpath] patchelf missing" >&2; exit 1; }

n=0
while IFS= read -r -d '' f; do
  # non-ELF files fail here
  rp="$(patchelf --print-rpath "$f" 2>/dev/null)" || continue
  [[ -n "$rp" ]] || continue
  dir="$(dirname "$f")"
  new=()
  IFS=: read -ra ents <<<"$rp"
  for e in "${ents[@]}"; do
    case "$e" in
      "$old"/*)
        t="${tree}/${e#"$old"/}"
        [[ -d "$t" ]] || continue
        new+=("\$ORIGIN/$(realpath -m --relative-to="$dir" "$t")") ;;
      *) new+=("$e") ;;
    esac
  done
  joined="$(IFS=:; echo "${new[*]}")"
  [[ "$joined" == "$rp" ]] && continue
  # DT_RPATH, as upstream ships
  patchelf --force-rpath --set-rpath "$joined" "$f"
  n=$((n + 1))
done < <(find "$tree" -type f -print0)

echo "[rpath] relativized ${n} ELF files under ${tree}"
