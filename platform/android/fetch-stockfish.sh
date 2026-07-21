#!/usr/bin/env bash
# Downloads the official prebuilt Stockfish Android binary (arm64-v8a) and
# installs it at the given destination, ready to be bundled as libstockfish.so
# in the APK (see make/android.mk). Cached under $XDG_CACHE_HOME so repeated
# builds don't re-download the ~110MB asset.
set -euo pipefail

abi="$1"
dest="$2"

case "$abi" in
    arm64-v8a) asset="stockfish-android-armv8" ;;
    armeabi-v7a) asset="stockfish-android-armv7" ;;
    *)
        echo "fetch-stockfish.sh: no prebuilt Stockfish for ABI '$abi', skipping." >&2
        exit 0
        ;;
esac

release="sf_18"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/koreader-stockfish"
cache_file="$cache_dir/$asset-$release"

mkdir -p "$cache_dir" "$(dirname "$dest")"

if [ ! -f "$cache_file" ]; then
    url="https://github.com/official-stockfish/Stockfish/releases/download/$release/$asset.tar"
    echo "Fetching $url..."
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -sL -o "$tmp/stockfish.tar" "$url"
    tar xf "$tmp/stockfish.tar" -C "$tmp" "stockfish/$asset"
    mv "$tmp/stockfish/$asset" "$cache_file"
    chmod 755 "$cache_file"
fi

cp -v "$cache_file" "$dest"
