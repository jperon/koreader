#!/usr/bin/env bash
# Builds Stockfish 11 (classic engine, ~1 MB, no NNUE network) for the given
# Android ABI and installs it at the destination, ready to be bundled as
# libstockfish.so in the APK (see make/android.mk). This script is standalone:
# it must not depend on any KOReader plugin. The source archive (official sf_11
# tag) is downloaded once and verified by sha256; build products are cached
# under $XDG_CACHE_HOME so repeated builds don't recompile.
set -euo pipefail

abi="${1:-}"
dest="${2:-}"

case "$abi" in
    arm64-v8a)
        sf_arch="general-64"
        clang_prefix="aarch64-linux-android21-clang++"
        ;;
    armeabi-v7a)
        sf_arch="armv7"
        clang_prefix="armv7a-linux-androideabi21-clang++"
        ;;
    *)
        echo "fetch-stockfish.sh: no Stockfish build for ABI '$abi', skipping." >&2
        exit 0
        ;;
esac

[ -n "$dest" ] || { echo "fetch-stockfish.sh: destination manquante" >&2; exit 1; }

sf_tag="sf_11"
sf_url="https://github.com/official-stockfish/Stockfish/archive/refs/tags/sf_11.tar.gz"
sf_sha256="802261cc601b67bed00c0ef7d21e2125959630f0852a06db9fc9bd74f440b199"
sf_dir="Stockfish-sf_11"

ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [ -z "$ndk" ]; then
    echo "fetch-stockfish.sh: ANDROID_NDK_HOME / ANDROID_NDK_ROOT not set" >&2
    exit 1
fi

host="linux-x86_64"
case "$(uname -s)" in
    Darwin) host="darwin-x86_64" ;;
esac
ndk_bin="$ndk/toolchains/llvm/prebuilt/$host/bin"
cxx="$ndk_bin/$clang_prefix"
[ -x "$cxx" ] || { echo "fetch-stockfish.sh: $cxx introuvable" >&2; exit 1; }

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/koreader-stockfish"
tarball="$cache_dir/$sf_tag.tar.gz"
cached_bin="$cache_dir/stockfish-$sf_tag-$abi"
mkdir -p "$cache_dir" "$(dirname "$dest")"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Fast path: reuse a previously built binary for this ABI.
if [ ! -f "$cached_bin" ]; then
    if [ ! -f "$tarball" ] || [ "$(sha256_of "$tarball")" != "$sf_sha256" ]; then
        echo "Fetching $sf_url..."
        tmp_dl="$(mktemp)"
        trap 'rm -f "$tmp_dl"' EXIT
        curl -fsSL -o "$tmp_dl" "$sf_url"
        got="$(sha256_of "$tmp_dl")"
        if [ "$got" != "$sf_sha256" ]; then
            echo "fetch-stockfish.sh: sha256 invalide (attendu $sf_sha256, obtenu $got)" >&2
            exit 1
        fi
        mv "$tmp_dl" "$tarball"
        trap - EXIT
    fi

    build_dir="$(mktemp -d)"
    trap 'rm -rf "$build_dir"' EXIT
    tar xzf "$tarball" -C "$build_dir"
    src="$build_dir/$sf_dir/src"
    [ -f "$src/Makefile" ] || { echo "fetch-stockfish.sh: Makefile introuvable" >&2; exit 1; }

    # OS=Android skips -lpthread and adds -fPIE/-pie (PIE required since API 21);
    # KERNEL=OpenBSD skips the -latomic that the clang branch adds (absent from
    # the NDK); ARCH!=armv7 keeps the ARMv7-only -march flag away from aarch64.
    # -static-libstdc++ links libc++ statically so the binary only needs
    # libc/libm/libdl, present on every device (strict static non-PIE is
    # rejected by recent Android and -static-pie fails on pthread_atfork).
    make -C "$src" build ARCH="$sf_arch" COMP=clang CXX="$cxx" \
        OS=Android KERNEL=OpenBSD EXTRALDFLAGS="-static-libstdc++"

    "$ndk_bin/llvm-strip" "$src/stockfish"
    cp "$src/stockfish" "$cached_bin"
    chmod 755 "$cached_bin"
fi

cp -v "$cached_bin" "$dest"
