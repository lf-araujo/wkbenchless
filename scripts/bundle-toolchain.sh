#!/usr/bin/env bash
# Assemble a self-contained toolchain next to the wkbenchless binary so config
# hot-reload (C-c r) works without a system Nim/C compiler.
#
# Layout it produces (wkbenchless's detectRebuildCmd looks here):
#   ./toolchain/nim/bin/nim   + ./toolchain/nim/lib + config  (Nim finds its
#                                                              stdlib beside it)
#   ./toolchain/zig/zig                                        (hermetic C backend)
#
# Usage:
#   scripts/bundle-toolchain.sh /path/to/zig
# where /path/to/zig is a zig binary (download the single-file release from
# https://ziglang.org/download/ and point at the extracted `zig`). Nim drives it
# as `zig cc`, which ships its own libc/headers and cross-compiles.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"     # project root
dest="$here/toolchain"
zig_src="${1:-}"

# 1. Copy the active Nim prefix (binary + lib + config) verbatim.
nim_bin="$(command -v nim || true)"
[ -n "$nim_bin" ] || { echo "error: no 'nim' on PATH to copy"; exit 1; }
nim_prefix="$(cd "$(dirname "$nim_bin")/.." && pwd)"   # .../nim-X.Y.Z
echo "copying Nim from $nim_prefix"
rm -rf "$dest/nim"
mkdir -p "$dest/nim"
cp -a "$nim_prefix/bin"    "$dest/nim/"
cp -a "$nim_prefix/lib"    "$dest/nim/"
[ -d "$nim_prefix/config" ] && cp -a "$nim_prefix/config" "$dest/nim/" || true

# 2. Place the zig binary (optional but recommended -- the compiler-free C path).
if [ -n "$zig_src" ]; then
  [ -x "$zig_src" ] || { echo "error: '$zig_src' is not an executable zig"; exit 1; }
  echo "copying zig from $zig_src"
  rm -rf "$dest/zig"; mkdir -p "$dest/zig"
  # zig needs its lib/ sibling; copy the whole zig dir if it has one.
  zdir="$(dirname "$zig_src")"
  if [ -d "$zdir/lib" ]; then cp -a "$zdir/." "$dest/zig/"; else cp -a "$zig_src" "$dest/zig/zig"; fi
  chmod +x "$dest/zig/zig"
else
  echo "note: no zig given -- bundling Nim only; C-c r will use the system C compiler."
fi

# 3. Nimble packages the build needs that are NOT vendored in-tree (pixie and
#    its deps; zippy and uirelays are vendored). A release install has no
#    ~/.nimble, so C-c r resolves them from here -- config.nims puts
#    toolchain/nim-pkgs on the path.
pkgs_dest="$dest/nim-pkgs"
rm -rf "$pkgs_dest"; mkdir -p "$pkgs_dest"
for base in "${HOME}/.nimble/pkgs2" "${HOME}/.nimble/pkgs"; do
  [ -d "$base" ] || continue
  for name in pixie bumpy chroma crunchy flatty nimsimd vmath; do
    for d in "$base/$name"-*; do
      [ -d "$d" ] || continue
      [ -d "$pkgs_dest/$(basename "$d")" ] || cp -a "$d" "$pkgs_dest/"
    done
  done
done
if [ -n "$(ls -A "$pkgs_dest" 2>/dev/null)" ]; then
  echo "nimble packages copied to $pkgs_dest"
else
  echo "warning: no nimble packages found -- run 'nimble install' first, or C-c r on a release install will not resolve pixie."
fi

echo "done. toolchain assembled at $dest"
echo "wkbenchless's C-c r will now prefer it (see detectRebuildCmd)."
