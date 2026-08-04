#!/usr/bin/env bash
#
# Builds the v4/v5 chains, in-container.
# Called by build.sh; lays out stow, vN.
# Env: DISTRO TIER CHAINS JOBS REVISION KEEP_BUILD
#
# Versions, order and layout follow upstream products.sh.
# We differ twice: binutils split, python rpath.
# Their per-product scripts are unpublished, so
# LLVM and gdb flags are reconstructed.
# arm64: --with-arch=armv8.2-a and no --with-tune.
# Their arm64 needs glibc 2.38, so per-distro.

set -euo pipefail

DISTRO="${DISTRO:?}"
TIER="${TIER:-rbe-essential}"
CHAINS="${CHAINS:-v4 v5}"
JOBS="${JOBS:-$(nproc)}"
REVISION="${REVISION:?}"
KEEP_BUILD="${KEEP_BUILD:-0}"

# cosmetic vendor; shapes the lib/gcc/<triple> layout
MONGO_TRIPLE="aarch64-mongodb-linux"
# explicit for non-gcc; no -mtune, as upstream
MARCH_FLAGS="-march=armv8.2-a"

# ── version pins ───────────────────────────────────────────────────
V_OPENSSL="1.1.1l"
V_CURL="7.79.1"
V_BISON="3.8.2"
V_SWIG="4.0.2"
V_LIBEDIT="20210910-3.1"
V_CMAKE="3.21.2"
V_NINJA="1.10.2"
# v4 chain (PSMDB 8.0)
# Upstream ships 2.37 on both; it cannot
# link deb13's glibc 2.41: RELR needs 2.38.
# Theirs must be patched; we use 2.40.
case "$DISTRO" in
  debian12) V4_BINUTILS="2.37" ;;
  *)        V4_BINUTILS="2.40" ;;   # debian13 + any newer/unknown distro: needs RELR
esac
V4_GCC="11.3.0"
V4_LLVM="12.0.1"      # confirmed: clang/llvm-config 12.0.1 in 93d85cc v4
V4_PYTHON="3.10.4"
V4_GDB="12.1"         # confirmed: gdb --version in 93d85cc v4
# v5 chain (PSMDB 8.3 / master)
V5_BINUTILS="2.43"    # confirmed: v5/bin/ld.bfd = "GNU LD 2.43" in arm64 93d85cc
V5_GCC="14.2.0"
V5_LLVM="19.1.7"      # confirmed: clang/llvm-config 19.1.7 in 93d85cc v5
V5_PYTHON="3.10.4"
V5_PYTHON313="3.13.11"
V5_GDB="17.1"         # confirmed: gdb --version in 93d85cc v5

# ── source integrity pins ──────────────────────────────────────────
# Trust-on-first-use, not checked against published sums.
# Stops later substitution and truncated downloads.
# fetch() prints unpinned hashes to copy in.
declare -A V_SHA256=(
  [openssl]="0b7a3e5e59c34827fe0c3a74b7ec8baef302b98fa80088d7f9153aa16fa76bd1"      # 1.1.1l
  [gcc-v4]="b47cf2818691f5b1e21df2bb38c795fac2cfbd640ede2d0a5e1c89e338a3ac39"       # 11.3.0
  [llvm-v4]="129cb25cd13677aad951ce5c2deb0fe4afc1e9d98950f53b51bdcfb5a73afa0e"      # 12.0.1
  [python3-v4]="80bf925f571da436b35210886cf79f6eb5fa5d6c571316b73568343451f77a19"   # 3.10.4
  [gdb-v4]="0e1793bf8f2b54d53f46dea84ccfd446f48f81b297b28c4f7fc017b818d69fed"       # 12.1
  [binutils-v5]="b53606f443ac8f01d1d5fc9c39497f2af322d99e14cea5c0b4b124d630379365"  # 2.43
  [gcc-v5]="a7b39bc69cbf9e25826c5a60ab26477001f7c08d85cec04bc0e29cabed6f3cc9"       # 14.2.0
  [llvm-v5]="82401fea7b79d0078043f7598b835284d6650a75b93e64b6f761ea7b63097501"      # 19.1.7
  [python3-v5]="80bf925f571da436b35210886cf79f6eb5fa5d6c571316b73568343451f77a19"   # 3.10.4
  [python313-v5]="16ede7bb7cdbfa895d11b0642fa0e523f291e6487194d53cf6d3b338c3a17ea2" # 3.13.11
  [gdb-v5]="14996f5f74c9f68f5a543fdc45bca7800207f91f92aeea6c2e791822c7c6d876"       # 17.1
  [cmake-v4]="94275e0b61c84bb42710f5320a23c6dcb2c6ee032ae7d2a616f53f68b3d21659"     # 3.21.2
  [cmake-v5]="94275e0b61c84bb42710f5320a23c6dcb2c6ee032ae7d2a616f53f68b3d21659"
  [ninja-v4]="ce35865411f0490368a8fc383f29071de6690cbadc27704734978221f25e2bed"     # 1.10.2
  [ninja-v5]="ce35865411f0490368a8fc383f29071de6690cbadc27704734978221f25e2bed"
  [bison-v4]="9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2"     # 3.8.2
  [bison-v5]="9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2"
  [libedit-v4]="6792a6a992050762edcca28ff3318cdb7de37dccf7bc30db59fcd7017eed13c5"   # 20210910-3.1
  [libedit-v5]="6792a6a992050762edcca28ff3318cdb7de37dccf7bc30db59fcd7017eed13c5"
  # [binutils-v4] missing: add after a clean run
)

ROOT="/opt/mongodbtoolchain/revisions/${REVISION}"
STOW="${ROOT}/stow"
LOGS="${ROOT}/logs"
SRC="/work/src"
mkdir -p "$STOW" "$LOGS" "$SRC" /out

# ── base build deps ────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential ca-certificates curl wget git xz-utils file rsync patch \
  gawk flex bison texinfo m4 perl \
  libgmp-dev libmpfr-dev libmpc-dev libisl-dev zlib1g-dev libexpat1-dev \
  libssl-dev libffi-dev libncurses-dev libxml2-dev liblzma-dev libcrypt-dev \
  libsqlite3-dev \
  python3 python3-dev pkg-config stow >/dev/null
echo "[deps] installed; host glibc: $(getconf GNU_LIBC_VERSION 2>/dev/null || ldd --version | head -1)"

# Upstream ships .info files, so we do.
# gcc 11.3's .texi trips deb13's texinfo;
# --force writes them anyway.
cat > /usr/local/bin/makeinfo-force <<'MEOF'
#!/bin/sh
makeinfo --force "$@" || true
MEOF
chmod +x /usr/local/bin/makeinfo-force

# manifest helper, as in products.sh
record() { echo "$2" > "${LOGS}/$1.manifest"; }
prefix_of() { cat "${LOGS}/$1.manifest"; }
have() { [[ -f "${LOGS}/$1.manifest" ]]; }

# No manifest means it never finished: debris.
# Mandatory for gcc, whose bootstrap cannot resume:
# a mixed-stage tree can miscompile silently.
fresh_build_dir() {
  local d="$1"
  if [[ -e "$d" ]]; then
    echo "[state] discarding unfinished build tree ${d}"
    rm -rf "$d"
  fi
  mkdir -p "$d"
}

# Keep the tree only if configure finished.
# Safe for ninja: it logs after success.
# Matters because llvm is the longest component.
resumable_build_dir() {
  local d="$1" sentinel="$2"
  if [[ -f "${d}/${sentinel}" ]]; then
    echo "[state] resuming build tree ${d}"
    return 0
  fi
  fresh_build_dir "$d"
}

fetch() {  # fetch URL DEST_DIR [strip] [sha_key]
  local url="$1" dest="$2" strip="${3:-1}" key="${4:-}"
  mkdir -p "$dest"
  echo "[fetch] $url"
  # a file, not a pipe: readable 404s
  local tmp; tmp="$(mktemp)"
  curl -fSL --retry 3 --retry-delay 2 -o "$tmp" "$url"
  # printed, so a first run pins it
  local got; got="$(sha256sum "$tmp" | awk '{print $1}')"
  echo "[fetch] sha256=${got}  (key=${key:-none})"
  if [[ -n "$key" ]]; then
    local want="${V_SHA256[$key]:-}"
    if [[ -z "$want" ]]; then
      echo "[fetch] WARNING: no sha256 pin for '${key}' — proceeding UNVERIFIED." >&2
      echo "[fetch]          add to V_SHA256:  [${key}]=\"${got}\"" >&2
    elif [[ "$want" != "$got" ]]; then
      echo "[fetch] SHA256 MISMATCH for ${url}" >&2
      echo "[fetch]   expected ${want}" >&2
      echo "[fetch]   got      ${got}" >&2
      rm -f "$tmp"; exit 1
    fi
  fi
  # explicit: tar may miss it on pipes
  local decomp
  case "$url" in
    *.tar.xz|*.txz)   decomp="xz -dc" ;;
    *.tar.gz|*.tgz)   decomp="gzip -dc" ;;
    *.tar.bz2|*.tbz2) decomp="bzip2 -dc" ;;
    *)                decomp="cat" ;;
  esac
  $decomp < "$tmp" | tar -x -C "$dest" --strip-components="$strip"
  rm -f "$tmp"
}

# ════════════════════════════════════════════════════════════════════
# shared components
# ════════════════════════════════════════════════════════════════════
build_openssl() {
  have openssl && return 0
  local d="${STOW}/openssl"; mkdir -p "$d"
  # openssl.org dropped 1.1.1; GitHub is immutable
  fetch "https://github.com/openssl/openssl/releases/download/OpenSSL_${V_OPENSSL//./_}/openssl-${V_OPENSSL}.tar.gz" "${SRC}/openssl" 1 openssl
  pushd "${SRC}/openssl" >/dev/null
  ./config --prefix="$d" --openssldir="$d" shared
  make -j"$JOBS"; make install_sw
  popd >/dev/null
  record openssl "$d"
}

# ════════════════════════════════════════════════════════════════════
# per-chain components.  $1 = v4|v5
# ════════════════════════════════════════════════════════════════════
chain_versions() {
  case "$1" in
    v4) BINUTILS="$V4_BINUTILS"; GCC="$V4_GCC"; LLVM="$V4_LLVM"; PY="$V4_PYTHON"; GCC_TRIPLE_VER="$V4_GCC" ;;
    v5) BINUTILS="$V5_BINUTILS"; GCC="$V5_GCC"; LLVM="$V5_LLVM"; PY="$V5_PYTHON"; GCC_TRIPLE_VER="$V5_GCC" ;;
  esac
}

build_binutils() {  # $1=chain
  local c="$1"; chain_versions "$c"
  have "binutils-${c}" && return 0
  local d="${STOW}/binutils-${c}"; mkdir -p "$d"
  fetch "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS}.tar.xz" "${SRC}/binutils-${c}" 1 "binutils-${c}"
  fresh_build_dir "${SRC}/binutils-${c}/build"; pushd "${SRC}/binutils-${c}/build" >/dev/null
  # native on the vendor triple: tool prefix
  ../configure --prefix="$d" \
    --build="$MONGO_TRIPLE" --host="$MONGO_TRIPLE" --target="$MONGO_TRIPLE" \
    --enable-gold --enable-ld=default --enable-plugins --enable-64-bit-bfd \
    --disable-werror --disable-nls --with-system-zlib
  make -j"$JOBS"; make install
  # unprefixed names, as BUILD.tmpl expects
  pushd "$d/bin" >/dev/null
  for t in as ld ld.bfd ld.gold ar nm objcopy objdump strip ranlib readelf dwp elfedit addr2line c++filt size strings gprof; do
    [[ -e "${MONGO_TRIPLE}-${t}" && ! -e "${t}" ]] && ln -sf "${MONGO_TRIPLE}-${t}" "${t}" || true
  done
  popd >/dev/null
  record "binutils-${c}" "$d"
}

build_gcc() {  # $1=chain
  local c="$1"; chain_versions "$c"
  have "gcc-${c}" && return 0
  build_binutils "$c"
  local d="${STOW}/gcc-${c}"; mkdir -p "$d"
  local bu; bu="$(prefix_of "binutils-${c}")"
  fetch "https://ftp.gnu.org/gnu/gcc/gcc-${GCC}/gcc-${GCC}.tar.xz" "${SRC}/gcc-${c}" 1 "gcc-${c}"
  pushd "${SRC}/gcc-${c}" >/dev/null
  ./contrib/download_prerequisites
  popd >/dev/null
  fresh_build_dir "${SRC}/gcc-${c}/build"; pushd "${SRC}/gcc-${c}/build" >/dev/null
  # Flags copied from their gcc's configuration_arguments.
  # No --with-sysroot: uses the container's headers.
  # PATH carries our binutils: matching as/ld.
  PATH="${bu}/bin:${PATH}" \
  ../configure \
    --prefix="$d" \
    --build="$MONGO_TRIPLE" \
    --with-arch=armv8.2-a \
    --disable-multilib \
    CFLAGS_FOR_TARGET= CXXFLAGS_FOR_TARGET= \
    --enable-__cxa_atexit \
    --with-linker-hash-style=gnu \
    --enable-gold \
    --enable-plugins \
    --enable-linker-build-id \
    --enable-shared \
    --enable-threads=posix \
    --enable-checking=release \
    --with-pic \
    --with-system-zlib \
    --enable-languages=c,c++,lto \
    --enable-bootstrap \
    --with-build-time-tools="${bu}/bin" \
    --disable-nls
  # gcc 11.3 sources trip gcc-14's default-errors.
  # Relaxed here only; the result is unaffected.
  local relax="-Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion"
  # see the makeinfo wrapper above
  PATH="${bu}/bin:${PATH}" make -j"$JOBS" MAKEINFO=/usr/local/bin/makeinfo-force \
    STAGE1_CFLAGS="-g -O2 ${relax}" CFLAGS_FOR_BUILD="-g -O2 ${relax}"
  make install MAKEINFO=/usr/local/bin/makeinfo-force
  popd >/dev/null
  # unprefixed names, as in mongodbtoolchain vN/bin
  pushd "$d/bin" >/dev/null
  for t in gcc g++ cpp gcov gcc-ar gcc-nm gcc-ranlib; do
    [[ -e "${MONGO_TRIPLE}-${t}" && ! -e "${t}" ]] && ln -sf "${MONGO_TRIPLE}-${t}" "${t}" || true
  done
  popd >/dev/null
  record "gcc-${c}" "$d"
}

build_python() {  # $1=chain  $2=version
  local c="$1" pv="$2"; chain_versions "$c"
  local tag="python3-${c}"
  have "$tag" && return 0
  build_openssl
  local d="${STOW}/${tag}"; mkdir -p "$d"
  local gcc ossl; gcc="$(prefix_of "gcc-${c}")"; ossl="$(prefix_of openssl)"
  fetch "https://www.python.org/ftp/python/${pv}/Python-${pv}.tar.xz" "${SRC}/${tag}" 1 "$tag"
  pushd "${SRC}/${tag}" >/dev/null
  # rpath everything, so python runs standalone:
  # gdb's probe needs it, else no python.
  # Only libcrypt.so.1 stays external, as upstream.
  CC="${gcc}/bin/gcc" CXX="${gcc}/bin/g++" CFLAGS="$MARCH_FLAGS" \
  LDFLAGS="-Wl,-rpath,${d}/lib -Wl,-rpath,${ossl}/lib -Wl,-rpath,${gcc}/lib64" \
  ./configure --prefix="$d" --enable-shared --with-openssl="$ossl" --with-system-ffi
  make -j"$JOBS"; make install
  # gdb's configure wants bin/python too
  if [[ -x "$d/bin/python3" && ! -e "$d/bin/python" ]]; then ln -sf python3 "$d/bin/python"; fi
  python_selftest "$d" "$tag"
  popd >/dev/null
  record "$tag" "$d"
}

# fail here, not later inside gdb's configure
python_selftest() {  # $1=prefix  $2=tag
  local d="$1" tag="$2"
  # _crypt is gone in 3.13; broke gdb
  if ! "$d/bin/python3" - <<'PY' 2>"${LOGS}/${tag}-selftest.err"
import sys
import ssl, ctypes, sqlite3, lzma, zlib   # hard requirements on every version
if sys.version_info < (3, 13):
    import _crypt                          # libcrypt.so.1 consumer; gone in 3.13
PY
  then
    echo "[python] bundled ${tag} interpreter cannot import required modules:" >&2
    cat "${LOGS}/${tag}-selftest.err" >&2
    echo "[python] ldd:" >&2; ldd "$d/bin/python3" >&2 || true
    exit 1
  fi
  echo "[python] ${tag} self-test OK ($("$d/bin/python3" --version 2>&1))"
}

build_python313() {  # v5 only
  have "python313-v5" && return 0
  build_openssl; build_gcc v5
  local d="${STOW}/python313-v5"; mkdir -p "$d"
  local gcc ossl; gcc="$(prefix_of gcc-v5)"; ossl="$(prefix_of openssl)"
  fetch "https://www.python.org/ftp/python/${V5_PYTHON313}/Python-${V5_PYTHON313}.tar.xz" "${SRC}/python313-v5" 1 python313-v5
  pushd "${SRC}/python313-v5" >/dev/null
  CC="${gcc}/bin/gcc" CXX="${gcc}/bin/g++" CFLAGS="$MARCH_FLAGS" \
  LDFLAGS="-Wl,-rpath,${d}/lib -Wl,-rpath,${ossl}/lib -Wl,-rpath,${gcc}/lib64" \
  ./configure --prefix="$d" --enable-shared --with-openssl="$ossl" --with-system-ffi
  make -j"$JOBS"; make install
  # `if`, so existing links survive set -e
  if [[ -x "$d/bin/python3" && ! -e "$d/bin/python" ]]; then ln -sf python3 "$d/bin/python"; fi
  python_selftest "$d" "python313-v5"
  popd >/dev/null
  record "python313-v5" "$d"
}

build_cmake() {  # $1=chain
  local c="$1"; have "cmake-${c}" && return 0
  build_gcc "$c"
  local d="${STOW}/cmake-${c}"; mkdir -p "$d"
  local gcc; gcc="$(prefix_of "gcc-${c}")"
  fetch "https://github.com/Kitware/CMake/releases/download/v${V_CMAKE}/cmake-${V_CMAKE}.tar.gz" "${SRC}/cmake-${c}" 1 "cmake-${c}"
  pushd "${SRC}/cmake-${c}" >/dev/null
  CC="${gcc}/bin/gcc" CXX="${gcc}/bin/g++" \
  ./bootstrap --prefix="$d" --parallel="$JOBS" -- -DCMAKE_USE_OPENSSL=OFF
  make -j"$JOBS"; make install
  popd >/dev/null
  record "cmake-${c}" "$d"
}

build_ninja() {  # $1=chain
  local c="$1"; have "ninja-${c}" && return 0
  build_gcc "$c"; build_cmake "$c"
  local d="${STOW}/ninja-${c}"; mkdir -p "$d/bin"
  local gcc cmake; gcc="$(prefix_of "gcc-${c}")"; cmake="$(prefix_of "cmake-${c}")"
  fetch "https://github.com/ninja-build/ninja/archive/refs/tags/v${V_NINJA}.tar.gz" "${SRC}/ninja-${c}" 1 "ninja-${c}"
  pushd "${SRC}/ninja-${c}" >/dev/null
  CC="${gcc}/bin/gcc" CXX="${gcc}/bin/g++" "${cmake}/bin/cmake" -Bbuild -DCMAKE_BUILD_TYPE=Release
  "${cmake}/bin/cmake" --build build -j"$JOBS"
  cp build/ninja "$d/bin/"
  popd >/dev/null
  record "ninja-${c}" "$d"
}

build_bison() {  # $1=chain
  local c="$1"; have "bison-${c}" && return 0
  build_gcc "$c"
  local d="${STOW}/bison-${c}"; mkdir -p "$d"
  local gcc; gcc="$(prefix_of "gcc-${c}")"
  fetch "https://ftp.gnu.org/gnu/bison/bison-${V_BISON}.tar.xz" "${SRC}/bison-${c}" 1 "bison-${c}"
  pushd "${SRC}/bison-${c}" >/dev/null
  CC="${gcc}/bin/gcc" ./configure --prefix="$d"
  make -j"$JOBS"; make install
  popd >/dev/null
  record "bison-${c}" "$d"
}

build_libedit() {  # $1=chain — llvm prereq (upstream: build-llvm-prereqs.sh -t libedit)
  local c="$1"; have "libedit-${c}" && return 0
  build_gcc "$c"
  local d="${STOW}/libedit-${c}"; mkdir -p "$d"
  local gcc ver; gcc="$(prefix_of "gcc-${c}")"; ver="${V_LIBEDIT}"
  fetch "https://www.thrysoee.dk/editline/libedit-${ver}.tar.gz" "${SRC}/libedit-${c}" 1 "libedit-${c}"
  pushd "${SRC}/libedit-${c}" >/dev/null
  CC="${gcc}/bin/gcc" LDFLAGS="-Wl,-rpath,${d}/lib" \
    ./configure --prefix="$d"
  make -j"$JOBS"; make install
  popd >/dev/null
  record "libedit-${c}" "$d"
}

build_llvm() {  # $1=chain
  local c="$1"; chain_versions "$c"
  have "llvm-${c}" && return 0
  # upstream order, from products.sh
  build_gcc "$c"; build_python "$c" "$PY"; build_cmake "$c"; build_ninja "$c"
  build_libedit "$c"
  local d="${STOW}/llvm-${c}"; mkdir -p "$d"
  local gcc py cm nj le; gcc="$(prefix_of "gcc-${c}")"; py="$(prefix_of "python3-${c}")"
  cm="$(prefix_of "cmake-${c}")"; nj="$(prefix_of "ninja-${c}")"; le="$(prefix_of "libedit-${c}")"
  fetch "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM}/llvm-project-${LLVM}.src.tar.xz" "${SRC}/llvm-${c}" 1 "llvm-${c}"
  resumable_build_dir "${SRC}/llvm-${c}/build" CMakeCache.txt; pushd "${SRC}/llvm-${c}/build" >/dev/null
  # Projects and targets read off their archive.
  #
  # The rpath split below is upstream's own:
  # v4 takes the SYSTEM libstdc++, 3.4.29 being
  # older than libicu needs; undefined symbols defer.
  # v5's 3.4.33 is newer, so uses bundled.
  #
  # DYLIB: upstream's biggest object is libLLVM.so,
  # with thin tools beside. Otherwise, fat.
  local llvm_targets; [[ "$c" == v4 ]] && llvm_targets="all" || llvm_targets="AArch64;X86;PowerPC;SystemZ"
  local link_flags
  if [[ "$c" == v4 ]]; then
    link_flags="-Wl,-rpath,\$ORIGIN/../lib -Wl,--allow-shlib-undefined"
  else
    # gcc/lib64 first, as upstream's v5 does
    link_flags="-Wl,-rpath,${gcc}/lib64 -Wl,-rpath,\$ORIGIN/../lib -L${gcc}/lib64"
  fi
  "${cm}/bin/cmake" -G Ninja "../llvm" \
    -DCMAKE_MAKE_PROGRAM="${nj}/bin/ninja" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$d" \
    -DCMAKE_C_COMPILER="${gcc}/bin/gcc" \
    -DCMAKE_CXX_COMPILER="${gcc}/bin/g++" \
    -DCMAKE_EXE_LINKER_FLAGS="${link_flags}" \
    -DCMAKE_SHARED_LINKER_FLAGS="${link_flags}" \
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;lldb;compiler-rt" \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DCLANG_LINK_CLANG_DYLIB=ON \
    -DLLVM_TARGETS_TO_BUILD="${llvm_targets}" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$MONGO_TRIPLE" \
    -DLIBEDIT_INCLUDE_DIR="${le}/include" \
    -DLIBEDIT_LIBRARY="${le}/lib/libedit.so" \
    -DPython3_EXECUTABLE="${py}/bin/python3"
  "${nj}/bin/ninja" -j"$JOBS"
  "${nj}/bin/ninja" install
  popd >/dev/null
  record "llvm-${c}" "$d"
}

build_gdb() {  # $1=chain
  local c="$1"; chain_versions "$c"
  have "gdb-${c}" && return 0
  build_gcc "$c"; build_python "$c" "$PY"
  local d="${STOW}/gdb-${c}"; mkdir -p "$d"
  local gcc py ossl; gcc="$(prefix_of "gcc-${c}")"; py="$(prefix_of "python3-${c}")"
  ossl="$(prefix_of openssl)"
  local gdbver; [[ "$c" == v4 ]] && gdbver="$V4_GDB" || gdbver="$V5_GDB"
  fetch "https://ftp.gnu.org/gnu/gdb/gdb-${gdbver}.tar.xz" "${SRC}/gdb-${c}" 1 "gdb-${c}"
  rm -rf "${SRC}/gdb-${c}/build"
  fresh_build_dir "${SRC}/gdb-${c}/build"; pushd "${SRC}/gdb-${c}/build" >/dev/null
  # configure-gdb runs during make and wants bin/python
  if [[ -x "${py}/bin/python3" && ! -e "${py}/bin/python" ]]; then ln -sf python3 "${py}/bin/python"; fi
  # env must reach the configure-gdb submake
  local py_ld="${py}/lib:${ossl}/lib:${gcc}/lib64"
  export LD_LIBRARY_PATH="${py_ld}:${LD_LIBRARY_PATH:-}"
  export PATH="${py}/bin:${PATH}"
  unset PYTHONHOME PYTHONPATH
  if ! LD_LIBRARY_PATH="${py_ld}" "${py}/bin/python3" -c 'import sys' 2>"${LOGS}/gdb-python-test.err"; then
    echo "[gdb] bundled python3 not runnable:" >&2
    cat "${LOGS}/gdb-python-test.err" >&2
    ldd "${py}/bin/python3" >&2 || true
    exit 1
  fi
  # gdb's python test links -lpython3.10, without -L.
  # Search path only: -lpython here breaks libiberty.
  CC="${gcc}/bin/gcc" CXX="${gcc}/bin/g++" \
    ../configure --prefix="$d" \
      --with-python="${py}" \
      --with-system-zlib \
      LDFLAGS="-L${py}/lib -Wl,-rpath,${py}/lib"
  # explicit env: configure-gdb comes from make.
  # MAKEINFO=true skips .info, as upstream does.
  LD_LIBRARY_PATH="${py_ld}" PATH="${py}/bin:${PATH}" make -j"$JOBS" MAKEINFO=true
  LD_LIBRARY_PATH="${py_ld}" PATH="${py}/bin:${PATH}" make install MAKEINFO=true
  popd >/dev/null
  record "gdb-${c}" "$d"
}

# ── full-tier extras (only when TIER=full) ─────────────────────────
build_full_extras() {  # $1=chain
  local c="$1"
  # upstream's set per products.sh; aflplusplus is v5-only
  echo "[full] extras for ${c} are NOT IMPLEMENTED:" >&2
  echo "       dwelfutils libabigail ccache bloaty iwyu swig(${V_SWIG})$([[ $c == v5 ]] && echo ' aflplusplus')" >&2
  echo "[full] their per-product build-*.sh (build-dwelfutils.sh, build-libabigail.sh," >&2
  echo "       build-ccache.sh, build-bloaty.sh, build-include-what-you-use.sh," >&2
  echo "       build-aflplusplus.sh) are NOT shipped in the upstream tarball." >&2
  echo "[full] refusing to ship a tarball labelled 'full' that is actually incomplete." >&2
  echo "       Use TIER=rbe-essential, or implement these first." >&2
  exit 1
}

# ════════════════════════════════════════════════════════════════════
# assemble vN/ trees: symlink stow/<pkg> into vN/
# ════════════════════════════════════════════════════════════════════
assemble_version_tree() {  # $1=chain (v4|v5)
  local c="$1"
  # from scratch: we add, never remove links
  local vdir="${ROOT}/${c}"; rm -rf "$vdir"; mkdir -p "$vdir"
  # later packages win on conflicts.
  #
  # openssl stays out, as upstream: python rpaths.
  # Merged, its 1.1.1 headers land in vN/include,
  # which gcc searches as vN/bin/gcc, and they
  # mix with the system 3.x ones. Everything
  # including openssl then dies on OPENSSL_API_COMPAT.
  local pkgs=()
  for p in "gcc-${c}" "binutils-${c}" "python3-${c}" "llvm-${c}" \
           "cmake-${c}" "ninja-${c}" "bison-${c}" "libedit-${c}" "gdb-${c}"; do
    have "$p" && pkgs+=("$(prefix_of "$p")")
  done
  [[ "$c" == v5 ]] && have python313-v5 && pkgs+=("$(prefix_of python313-v5)")
  echo "[assemble] ${c}: ${#pkgs[@]} packages -> ${vdir}"
  for pdir in "${pkgs[@]}"; do
    ( cd "$pdir" && find . -mindepth 1 -type d -printf '%P\0' | \
        while IFS= read -r -d '' sub; do mkdir -p "${vdir}/${sub}"; done )
    # relative, so the tree survives extraction anywhere
    ( cd "$pdir" && find . -mindepth 1 \( -type f -o -type l \) -printf '%P\0' | \
        while IFS= read -r -d '' f; do ln -sfr "${pdir}/${f}" "${vdir}/${f}"; done )
  done
  # upstream ships these empty; kept for parity
  if [[ "$c" == v5 ]]; then
    : > "${vdir}/clang.cfg"
    : > "${vdir}/clang++.cfg"
  fi
}

# ════════════════════════════════════════════════════════════════════
# smoke: use the tree as consumers will,
# in this container, before anything ships
# ════════════════════════════════════════════════════════════════════
smoke_test() {  # $1=chain
  local c="$1"; local v="${ROOT}/${c}"
  echo "[smoke] ${c}: exercising ${v}"
  # mirrors each chain's libstdc++ model; see build_llvm
  local run_ld
  if [[ "$c" == v4 ]]; then run_ld="${v}/lib"; else run_ld="${v}/lib:${v}/lib64"; fi
  local tmp; tmp="$(mktemp -d)"

  # C: gcc, our as/ld, host glibc
  printf 'int main(void){return 0;}\n' > "${tmp}/t.c"
  "${v}/bin/gcc" -march=armv8.2-a "${tmp}/t.c" -o "${tmp}/tc"
  LD_LIBRARY_PATH="$run_ld" "${tmp}/tc"

  # C++: catches the GLIBCXX failures
  printf '#include <string>\n#include <iostream>\nint main(){std::string s="ok";std::cout<<s<<"\\n";return 0;}\n' > "${tmp}/t.cpp"
  "${v}/bin/g++" "${tmp}/t.cpp" -o "${tmp}/tcpp"
  LD_LIBRARY_PATH="$run_ld" "${tmp}/tcpp" >/dev/null

  # --version forces the load: v4 defers libicu
  LD_LIBRARY_PATH="$run_ld" "${v}/bin/clang" --version >/dev/null
  LD_LIBRARY_PATH="$run_ld" "${v}/bin/lldb"  --version >/dev/null

  # python: interpreter plus extension modules
  LD_LIBRARY_PATH="$run_ld" "${v}/bin/python3" \
    -c 'import sys,ssl,ctypes,sqlite3,lzma,zlib; print("py",sys.version.split()[0])' >/dev/null

  # gdb: must run and embed python
  LD_LIBRARY_PATH="$run_ld" "${v}/bin/gdb" --version >/dev/null
  LD_LIBRARY_PATH="$run_ld" "${v}/bin/gdb" -nx -batch -ex 'python import sys; print("gdb-py", sys.version.split()[0])' >/dev/null

  rm -rf "$tmp"
  echo "[smoke] ${c}: OK"
}

# ════════════════════════════════════════════════════════════════════
# main
# ════════════════════════════════════════════════════════════════════
for c in $CHAINS; do
  echo "######## building chain ${c} ########"
  build_gcc "$c"
  # build-time only: gcc-14's helpers need its
  # newer GLIBCXX to run, e.g. cmake's test
  export LD_LIBRARY_PATH="$(prefix_of "gcc-${c}")/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  build_llvm "$c"    # pulls python/cmake/ninja/libedit internally (upstream order)
  build_bison "$c"
  build_gdb "$c"
  [[ "$c" == v5 ]] && build_python313
  [[ "$TIER" == full ]] && build_full_extras "$c"
  assemble_version_tree "$c"
  smoke_test "$c"
done

strip_installed_tree() {
  # upstream strips this; unstripped costs 1.4 GiB
  #
  # --strip-all keeps .dynsym, so linking works.
  # Archives get --strip-debug, else unlinkable.
  local before after
  before=$(du -sm "$STOW" | cut -f1)
  find "$STOW" -type f -print0 | while IFS= read -r -d '' f; do
    case "$(file -b "$f")" in
      *ELF*executable*|*ELF*shared\ object*) strip --strip-all "$f" 2>/dev/null || true ;;
      *ar\ archive*)                         strip --strip-debug "$f" 2>/dev/null || true ;;
    esac
  done
  after=$(du -sm "$STOW" | cut -f1)
  echo "[strip] ${STOW}: ${before} MiB -> ${after} MiB"
}
strip_installed_tree
# the smoke above ran unstripped; this ships
for c in $CHAINS; do smoke_test "$c"; done

export ROOT STOW LOGS REVISION DISTRO CHAINS MONGO_TRIPLE
bash /scripts/bazel-repack.sh

# contents, not $SRC: a bind-mount under PERSIST
if [[ "$KEEP_BUILD" != "1" ]]; then
  rm -rf "${SRC:?}"/* "${SRC:?}"/.[!.]* 2>/dev/null || true
fi
echo "[components] done for ${DISTRO}"
