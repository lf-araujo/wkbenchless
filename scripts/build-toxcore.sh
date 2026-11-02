#!/usr/bin/env bash
# Build c-toxcore and libsodium as static libraries into one prefix, so the
# Tox tunnel (extensions/tox_collab.nim via nim-tuntox) links into a binary
# that needs neither library at runtime. CI and release.yml use this on
# Linux, macOS and Windows (MSYS2 MINGW64 shell); it works for a local build too.
#
#   scripts/build-toxcore.sh <prefix>
#   export PKG_CONFIG_PATH=<prefix>/lib/pkgconfig   # then build wkbenchless
#
# HOST=x86_64-w64-mingw32 cross-builds for Windows from Linux.
# Only static archives are installed in <prefix>, so the linker cannot pick a
# shared libsodium / libtoxcore by accident.
set -euo pipefail

PREFIX="${1:?usage: build-toxcore.sh <prefix>}"
SODIUM_VERSION="${SODIUM_VERSION:-1.0.20}"
TOXCORE_VERSION="${TOXCORE_VERSION:-v0.2.19}"
HOST="${HOST:-}"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"
# MSYS2: the compilers and pkg-config are native Windows programs, so hand
# them D:/a/... paths, not /d/a/... (those reach the .pc files too).
if command -v cygpath >/dev/null 2>&1; then PREFIX="$(cygpath -m "$PREFIX")"; fi
WORK="$PREFIX/_src"
mkdir -p "$WORK"

if [ -f "$PREFIX/lib/pkgconfig/toxcore.pc" ] && [ -f "$PREFIX/lib/libsodium.a" ]; then
  echo "build-toxcore: already built in $PREFIX"
  exit 0
fi

# -- libsodium ---------------------------------------------------------------
if [ ! -f "$PREFIX/lib/libsodium.a" ]; then
  cd "$WORK"
  tarball="libsodium-$SODIUM_VERSION.tar.gz"
  [ -f "$tarball" ] || curl -fsSL -o "$tarball" \
    "https://github.com/jedisct1/libsodium/releases/download/$SODIUM_VERSION-RELEASE/$tarball"
  rm -rf "libsodium-$SODIUM_VERSION"
  tar xzf "$tarball"
  cd "libsodium-$SODIUM_VERSION"
  ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib" ${HOST:+--host=$HOST} \
    --disable-shared --enable-static --with-pic --disable-dependency-tracking
  make -j"$JOBS"
  make install
fi

# -- c-toxcore ---------------------------------------------------------------
cd "$WORK"
if [ ! -d c-toxcore ]; then
  git clone --depth 1 --branch "$TOXCORE_VERSION" --recurse-submodules \
    --shallow-submodules https://github.com/TokTok/c-toxcore c-toxcore
fi
cmake_args=(
  -S c-toxcore -B c-toxcore/_build
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DENABLE_STATIC=ON -DENABLE_SHARED=OFF -DBUILD_TOXAV=OFF -DMUST_BUILD_TOXAV=OFF
  -DUNITTEST=OFF -DAUTOTEST=OFF -DBOOTSTRAP_DAEMON=OFF -DDHT_BOOTSTRAP=OFF
  -DBUILD_FUN_UTILS=OFF -DBUILD_FUZZ_TESTS=OFF
)
if command -v ninja >/dev/null 2>&1; then cmake_args+=(-G Ninja); fi
if [ -n "$HOST" ]; then
  cmake_args+=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_C_COMPILER="$HOST-gcc"
               -DCMAKE_CXX_COMPILER="$HOST-g++" -DCMAKE_RC_COMPILER="$HOST-windres"
               -DCMAKE_FIND_ROOT_PATH="$PREFIX")
fi
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
  cmake "${cmake_args[@]}"
cmake --build c-toxcore/_build --parallel "$JOBS"
cmake --install c-toxcore/_build

# The .pc files keep the absolute prefix: CI restores its cache at the same path.
rm -rf "$WORK"
echo "build-toxcore: done -- export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig"
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" pkg-config --static --libs toxcore
