#!/usr/bin/env bash
#
# arm64 MongoDB toolchain for Debian 12/13.
# v8.0 uses chain v4, v8.3+ uses v5.
# Own base image per distro: glibc links.
# Needs a native aarch64 host.
# Targets need libcrypt1, libxml2, libicu.
#
# Usage: ./build.sh [debian12|debian13|all]
# Env: TIER CHAINS JOBS REVISION OUTPUT_DIR PERSIST
# PERSIST state is per distro, not pin.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_ARG="${1:-all}"

TIER="${TIER:-rbe-essential}"
CHAINS="${CHAINS:-v4 v5}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
REVISION="${REVISION:-$(date +%Y%m%d)-percona-arm64}"
OUTPUT_DIR="${OUTPUT_DIR:-${HERE}/out}"
KEEP_BUILD="${KEEP_BUILD:-0}"
PERSIST="${PERSIST:-0}"

case "$TARGET_ARG" in
  debian12) DISTROS=(debian12) ;;
  debian13) DISTROS=(debian13) ;;
  all)      DISTROS=(debian12 debian13) ;;
  *) echo "usage: $0 [debian12|debian13|all]" >&2; exit 1 ;;
esac

declare -A BASE_IMAGE=(
  [debian12]="debian:bookworm"
  [debian13]="debian:trixie"
)

if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then
  echo "WARNING: host arch is $(uname -m), not aarch64."
  echo "         Docker must emulate linux/arm64 (slow) or this will produce x86_64 binaries."
  echo "         A native aarch64 host is strongly recommended."
fi

mkdir -p "$OUTPUT_DIR"

for distro in "${DISTROS[@]}"; do
  img="${BASE_IMAGE[$distro]}"
  echo "============================================================"
  echo " Building toolchain for ${distro} (${img})"
  echo "   TIER=${TIER}  CHAINS='${CHAINS}'  JOBS=${JOBS}  REVISION=${REVISION}  PERSIST=${PERSIST}"
  echo "============================================================"

  # host-side tree, so reruns skip finished components
  persist_mounts=()
  if [[ "$PERSIST" == "1" ]]; then
    state_dir="${OUTPUT_DIR}/state/${distro}"
    mkdir -p "${state_dir}/opt" "${state_dir}/src"
    echo "   PERSIST on -> state: ${state_dir}"
    persist_mounts=(
      -v "${state_dir}/opt:/opt/mongodbtoolchain:rw"
      -v "${state_dir}/src:/work/src:rw"
    )
  fi

  docker run --rm \
    --platform linux/arm64 \
    -v "${HERE}:/scripts:ro" \
    -v "${OUTPUT_DIR}:/out:rw" \
    "${persist_mounts[@]}" \
    -e DISTRO="${distro}" \
    -e TIER="${TIER}" \
    -e CHAINS="${CHAINS}" \
    -e JOBS="${JOBS}" \
    -e REVISION="${REVISION}" \
    -e KEEP_BUILD="${KEEP_BUILD}" \
    -w /work \
    "${img}" \
    bash /scripts/components.sh
done

echo
echo "Done. Artifacts in: ${OUTPUT_DIR}"
ls -la "${OUTPUT_DIR}"
echo
echo "Next steps for RBE integration (per distro/chain):"
echo "  1. Upload bazel_vN_toolchain-<distro>-arm64-<id>.tar.gz to an HTTP source"
echo "     (S3 boxes-style bucket / downloads.percona.com)."
echo "  2. Paste the generated .bzl snippet into:"
echo "       v8.0:          bazel/toolchains/cc/mongo_linux/mongo_toolchain_version_v4.bzl"
echo "       v8.3 / master: bazel/toolchains/cc/mongo_linux/mongo_toolchain_version_v5.bzl"
echo "     adding key \"<distro>_aarch64\" with url + sha256 (sha256 is in the .sha256 file)."
echo "  3. For the legacy SCons / psmdb_builder.sh path, publish the stow tarball as"
echo "     \${OS_CODE_NAME}_mongodbtoolchain_aarch64.tar.gz."
