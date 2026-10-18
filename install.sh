#!/bin/sh
# Install hoard from a GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/qrazil/hoard/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --version 0.1.0 --dir /usr/local/bin
#
# Detects the OS and architecture, downloads the release tarball and
# SHA256SUMS, checks the tarball against it, and installs the binary to
# ~/.local/bin (or --dir). Nothing is installed if the checksum does not match.
set -eu

REPO="qrazil/hoard"
version=""
dir="${HOME}/.local/bin"
while [ $# -gt 0 ]; do
    case "$1" in
        --version) version="${2:?--version needs a value}"; shift 2 ;;
        --dir) dir="${2:?--dir needs a value}"; shift 2 ;;
        *) echo "install.sh: unknown argument '$1' (--version X, --dir PATH)" >&2; exit 64 ;;
    esac
done

case "$(uname -s)/$(uname -m)" in
    Linux/x86_64|Linux/amd64) asset="linux-x86_64" ;;
    Linux/aarch64|Linux/arm64) asset="linux-aarch64" ;;
    Darwin/arm64) asset="macos-arm64" ;;
    *) echo "install.sh: no hoard build for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

if [ -z "$version" ]; then
    base="https://github.com/${REPO}/releases/latest/download"
else
    base="https://github.com/${REPO}/releases/download/v${version#v}"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/hoard.tar.gz" "$base/hoard-${asset}.tar.gz"
curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"

want=$(awk -v f="hoard-${asset}.tar.gz" '$2 == f || $2 == "*"f {print $1}' "$tmp/SHA256SUMS")
if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$tmp/hoard.tar.gz" | awk '{print $1}')
else
    got=$(shasum -a 256 "$tmp/hoard.tar.gz" | awk '{print $1}')
fi
if [ -z "$want" ] || [ "$want" != "$got" ]; then
    echo "install.sh: checksum mismatch for hoard-${asset}.tar.gz; nothing installed" >&2
    exit 1
fi

tar -C "$tmp" -xzf "$tmp/hoard.tar.gz"
mkdir -p "$dir"
cp "$tmp/hoard" "$dir/hoard.new"
chmod 755 "$dir/hoard.new"
mv "$dir/hoard.new" "$dir/hoard"
echo "installed $("$dir/hoard" --version) to $dir/hoard"
case ":$PATH:" in
    *":$dir:"*) ;;
    *) echo "note: $dir is not on PATH" ;;
esac
