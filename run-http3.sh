#!/bin/sh
# Isolated HTTP3 curl for Linux aarch64/OpenWrt; no opkg changes.
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
fail() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'Run as root over SSH'
[ -n "${SSH_CONNECTION:-}" ] || fail 'An SSH session is required'
case "$(uname -m)" in aarch64|arm64) ;; *) fail 'This portable curl is for aarch64 only';; esac
for c in wget tar sha256sum awk mktemp; do
    command -v "$c" >/dev/null || fail "Missing dependency: $c"
done
[ ! -d /tmp/youtube-test.lock ] || fail 'Another test or unfinished transaction exists'
[ "$(df -Pk /tmp | awk 'END{print $4}')" -ge 32768 ] || fail 'Need 32 MiB free in /tmp'
tools=$(mktemp -d /tmp/youtube-http3.XXXXXX) || fail 'Cannot create private temporary directory'
# Keep the tools after launching: detached worker still needs this binary.
printf '\033[36mPreparing portable HTTP3 curl in %s\033[0m\n' "$tools"
archive="$tools/curl.tar.xz"
wget -O "$archive" https://github.com/stunnel/static-curl/releases/download/8.23.0-1/curl-linux-aarch64-musl-8.23.0-1.tar.xz || fail 'Portable curl download failed'
printf '%s  %s\n' e20f26e5b87c1883608f286f86bdabf39d3b8556e8a8e75dfe205e14bd206199 "$archive" | sha256sum -c - || fail 'Archive checksum mismatch'
tar -xJf "$archive" -C "$tools" curl || fail 'tar cannot extract xz; need tar with xz support or xz-utils (nothing installed)'
printf '%s  %s\n' 3a7c6818343f1b5184047bb484cb3cff7d5ede35a2713a6ef61030b422d8d6fc "$tools/curl" | sha256sum -c - || fail 'Binary checksum mismatch'
chmod 700 "$tools/curl"
"$tools/curl" --version > "$tools/version.txt" || fail 'Portable curl cannot run on this router'
cat "$tools/version.txt"
grep -qw HTTP3 "$tools/version.txt" || fail 'Portable curl has no HTTP3 feature'
rm -f "$archive"
# Pin the tested driver, so future changes to main cannot alter this launch.
wget -O "$tools/youtube-test.sh" https://raw.githubusercontent.com/TMN88/zapret2_strategy_podbor_script/5f6a8db0894d6a183cdad0ef66717f5bf14a4bea/youtube-test.sh || fail 'Driver download failed'
printf '%s  %s\n' 9ea98ed5470430c9fc8cbae08662f5d445e5ac2745c25df848535bc1000250bb "$tools/youtube-test.sh" | sha256sum -c - || fail 'Driver checksum mismatch'
printf '\033[36mSystem curl/libcurl unchanged. Temporary tools: %s\033[0m\n' "$tools"
CURL_BIN="$tools/curl" YT_FOLLOW=1 sh "$tools/youtube-test.sh"
