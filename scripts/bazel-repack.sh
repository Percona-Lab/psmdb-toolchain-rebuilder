#!/usr/bin/env bash
#
# Runs after components.sh, in-container. Into /out:
#   mongodbtoolchain-<distro>-arm64-<rev>.tar.gz  stow layout + install.sh
#   bazel_v{4,5}_toolchain-<distro>-arm64-<rev>.tar.gz  Bazel layout
#   bazel_v5_gdb-<distro>-arm64-<rev>.tar.gz  for the @gdb repo
#   <artifact>.sha256 and a .bzl snippet to paste
#
# Bazel archives: vN/ and stow/ at root,
# no revision prefix, as flags .bzl expects.

set -euo pipefail

ROOT="${ROOT:?}"                 # /opt/mongodbtoolchain/revisions/<rev>
STOW="${STOW:?}"
LOGS="${LOGS:?}"
REVISION="${REVISION:?}"
DISTRO="${DISTRO:?}"
CHAINS="${CHAINS:?}"

REV_DIR_NAME="$(basename "$ROOT")"
REVS_PARENT="$(dirname "$ROOT")"          # /opt/mongodbtoolchain/revisions
OUT="/out"

sha_and_snippet() {  # $1=artifact-path  $2=chain(v4|v5)  $3=kind: toolchain(default)|gdb
  local art="$1" chain="$2" kind="${3:-toolchain}"
  local sum; sum="$(sha256sum "$art" | awk '{print $1}')"
  echo "$sum  $(basename "$art")" > "${art}.sha256"
  local key="${DISTRO}_aarch64"
  local bzl name
  if [[ "$kind" == gdb ]]; then
    bzl="mongo_gdb_version_${chain}.bzl"; name="${chain}-gdb-${DISTRO}"
  else
    bzl="mongo_toolchain_version_${chain}.bzl"; name="${chain}-${DISTRO}"
  fi
  cat > "${OUT}/${name}-bzl-snippet.txt" <<EOF
# Paste into bazel/toolchains/cc/mongo_linux/${bzl}
# inside TOOLCHAIN_MAP_${chain^^} = { ... }
    "${key}": {
        "platform_name": "${DISTRO}-arm64",
        "sha": "${sum}",
        "url": "REPLACE_WITH_HTTP_URL/$(basename "$art")",
    },
EOF
  echo "[snippet] wrote ${OUT}/${name}-bzl-snippet.txt (sha=${sum})"
}

# ── 1) stow tarball (+ minimal install.sh) ─────────────────────────
build_stow_tarball() {
  cat > "${ROOT}/install.sh" <<'INST'
#!/usr/bin/env bash
# Links /opt/mongodbtoolchain/vN and absolutizes its symlinks.
# Relative links keep the tarball relocatable, but
# vN is a symlink, so prefix-from-argv0 misses.
# Upstream absolutizes too.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/opt/mongodbtoolchain"
mkdir -p "$TARGET"
for v in v4 v5; do
  [[ -d "$HERE/$v" ]] || continue
  echo "absolutizing symlinks in $HERE/$v ..."
  find "$HERE/$v/" -type l | while IFS= read -r f; do
    case "$(readlink "$f")" in /*) continue ;; esac   # already absolute -> skip
    tgt="$(readlink -f "$f" 2>/dev/null)" || continue
    [[ -e "$tgt" ]] && ln -sfn "$tgt" "$f"
  done
  rm -rf "$TARGET/$v"
  ln -sfn "$HERE/$v" "$TARGET/$v"
  echo "linked $TARGET/$v -> $HERE/$v (symlinks absolutized)"
done
INST
  chmod +x "${ROOT}/install.sh"

  local out="${OUT}/mongodbtoolchain-${DISTRO}-arm64-${REVISION}.tar.gz"
  echo "[stow] packing ${out}"
  # as-is: vN are relative symlinks into ./stow
  tar -C "$REVS_PARENT" -czf "$out" "$REV_DIR_NAME"
  echo "[stow] $(du -h "$out" | cut -f1)  ${out}"
}

# ── 2) bazel-layout tarball, per chain ─────────────────────────────
build_bazel_tarball() {  # $1=chain
  local c="$1"
  [[ -d "${ROOT}/${c}" ]] || { echo "[bazel] no ${c} tree, skip"; return 0; }

  # upstream's set: gcc, llvm, libedit.
  # Bazel has own python; gdb from @gdb.
  # binutils is ours; upstream folds into gcc.
  local stage; stage="$(mktemp -d)"
  cp -a "${ROOT}/${c}" "${stage}/${c}"
  mkdir -p "${stage}/stow"
  for p in "gcc-${c}" "binutils-${c}" "llvm-${c}" "libedit-${c}"; do
    [[ -d "${STOW}/${p}" ]] && cp -a "${STOW}/${p}" "${stage}/stow/${p}"
  done
  # vN merged everything; drop the skipped links
  find "${stage}/${c}" -xtype l -delete
  find "${stage}/${c}" -type d -empty -delete

  local art="${OUT}/bazel_${c}_toolchain-${DISTRO}-arm64-${REVISION}.tar.gz"
  echo "[bazel] packing ${art}"
  tar -C "$stage" -czf "$art" "${c}" stow
  rm -rf "$stage"
  echo "[bazel] $(du -h "$art" | cut -f1)  ${art}"
  sha_and_snippet "$art" "$c"
}

# ── 3) slim gdb tarball (v5 only) ──────────────────────────────────
# @gdb needs only gdb and its python.
# Matches theirs: no gcc libs, system libstdc++.
# The full v5 archive would duplicate it.
build_gdb_tarball() {
  local c=v5
  [[ -d "${ROOT}/${c}" && -d "${STOW}/gdb-${c}" ]] || { echo "[gdb] no ${c} gdb, skip"; return 0; }
  local stage; stage="$(mktemp -d)"
  cp -a "${ROOT}/${c}" "${stage}/${c}"
  mkdir -p "${stage}/stow"
  cp -a "${STOW}/gdb-${c}" "${stage}/stow/gdb-${c}"
  cp -a "${STOW}/python3-${c}" "${stage}/stow/python3-${c}"
  # leaves the merge of what ships
  find "${stage}/${c}" -xtype l -delete
  find "${stage}/${c}" -type d -empty -delete
  bash "$(dirname "${BASH_SOURCE[0]}")/relativize-rpath.sh" "$stage" "$ROOT"
  local art="${OUT}/bazel_${c}_gdb-${DISTRO}-arm64-${REVISION}.tar.gz"
  echo "[gdb] packing ${art}"
  tar -C "$stage" -czf "$art" "${c}" stow
  rm -rf "$stage"
  echo "[gdb] $(du -h "$art" | cut -f1)  ${art}"
  sha_and_snippet "$art" "$c" gdb
}

build_stow_tarball
for c in $CHAINS; do
  build_bazel_tarball "$c"
done
[[ " $CHAINS " == *" v5 "* ]] && build_gdb_tarball

echo "[repack] artifacts:"
ls -la "$OUT"
