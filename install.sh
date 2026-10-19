#!/bin/sh
# Install hoard: a release binary from GitHub, or a build from source.
#
#   curl -fsSL https://raw.githubusercontent.com/qrazil/hoard/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --version 0.1.0 --dir /usr/local/bin
#   curl -fsSL .../install.sh | sh -s -- --source https://git.example.org/hoard/archive/v0.1.0.tar.gz
#
# Binary mode detects the OS and architecture, downloads the release tarball
# and SHA256SUMS, checks the tarball against it, and installs the binary to
# ~/.local/bin (or --dir). Nothing is installed if the checksum does not match.
#
# Source mode (--source URL) is for a hoard server that serves its own tag
# tarballs, which are source code and so the same for every platform. It
# downloads that tarball, then the m31 release (compiler and runtime) named
# in the tarball's M31_VERSION file, checked against m31's SHA256SUMS, and
# builds with the system C compiler (cc, or $CC). --sha256 HASH checks the
# source tarball too; without it the source is trusted as served, so use an
# https URL you control.
set -eu

REPO="qrazil/hoard"
M31_REPO="qrazil/m31"
version=""
source_url=""
source_sha=""
dir="${HOME}/.local/bin"
while [ $# -gt 0 ]; do
    case "$1" in
        --version) version="${2:?--version needs a value}"; shift 2 ;;
        --dir) dir="${2:?--dir needs a value}"; shift 2 ;;
        --source) source_url="${2:?--source needs a URL}"; shift 2 ;;
        --sha256) source_sha="${2:?--sha256 needs a hash}"; shift 2 ;;
        *) echo "install.sh: unknown argument '$1' (--version X, --dir PATH, --source URL, --sha256 HASH)" >&2; exit 64 ;;
    esac
done

case "$(uname -s)/$(uname -m)" in
    Linux/x86_64|Linux/amd64) asset="linux-x86_64" ;;
    Linux/aarch64|Linux/arm64) asset="linux-aarch64" ;;
    Darwin/arm64) asset="macos-arm64" ;;
    *) echo "install.sh: no hoard or m31 build for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# fetch BASE NAME: download BASE/NAME and check it against BASE/SHA256SUMS.
fetch_checked() {
    curl -fsSL -o "$tmp/$2" "$1/$2"
    curl -fsSL -o "$tmp/SHA256SUMS" "$1/SHA256SUMS"
    want=$(awk -v f="$2" '$2 == f || $2 == "*"f {print $1}' "$tmp/SHA256SUMS")
    got=$(sha256 "$tmp/$2")
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
        echo "install.sh: checksum mismatch for $2; nothing installed" >&2
        exit 1
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -n "$source_url" ]; then
    command -v "${CC:-cc}" >/dev/null 2>&1 || {
        echo "install.sh: building from source needs a C compiler (cc, or set CC)" >&2
        exit 1
    }
    curl -fsSL -o "$tmp/source.tar.gz" "$source_url"
    if [ -n "$source_sha" ] && [ "$(sha256 "$tmp/source.tar.gz")" != "$source_sha" ]; then
        echo "install.sh: the source tarball does not match --sha256; nothing installed" >&2
        exit 1
    fi
    mkdir "$tmp/source"
    tar -C "$tmp/source" --strip-components=1 -xzf "$tmp/source.tar.gz"
    [ -f "$tmp/source/M31_VERSION" ] || {
        echo "install.sh: $source_url is not a hoard source tarball (no M31_VERSION)" >&2
        exit 1
    }
    m31_version=$(tr -d ' \n' < "$tmp/source/M31_VERSION")
    fetch_checked "https://github.com/${M31_REPO}/releases/download/${m31_version}" "m31-${asset}.tar.gz"
    mkdir "$tmp/m31"
    tar -C "$tmp/m31" -xzf "$tmp/m31-${asset}.tar.gz"
    chmod +x "$tmp/m31/m31c"
    echo "building hoard with m31 ${m31_version}..."
    (cd "$tmp/source" && M31_ROOT="$tmp/m31" LANGC="$tmp/m31/m31c" bash scripts/build.sh -o "$tmp/hoard") >/dev/null
else
    if [ -z "$version" ]; then
        base="https://github.com/${REPO}/releases/latest/download"
    else
        base="https://github.com/${REPO}/releases/download/v${version#v}"
    fi
    fetch_checked "$base" "hoard-${asset}.tar.gz"
    tar -C "$tmp" -xzf "$tmp/hoard-${asset}.tar.gz"
fi

mkdir -p "$dir"
cp "$tmp/hoard" "$dir/hoard.new"
chmod 755 "$dir/hoard.new"
mv "$dir/hoard.new" "$dir/hoard"
echo "installed $("$dir/hoard" --version) to $dir/hoard"
case ":$PATH:" in
    *":$dir:"*) ;;
    *) echo "note: $dir is not on PATH" ;;
esac
