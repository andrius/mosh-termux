#!/usr/bin/env bash
# Build a patched mosh-client.
#
#   bash build.sh            # build only
#   bash build.sh --install  # build, then replace the installed mosh-client
#
# Runs both on a Termux device and on an ordinary Linux box. On Termux it
# installs its own build dependencies; elsewhere it expects them to be present,
# which is what the CI behaviour check relies on.
set -euo pipefail

VERSION=1.4.0
SHA256=872e4b134e5df29c8933dff12350785054d2fd2839b5ae6b5587b14db1465ddd
TARBALL=mosh-${VERSION}.tar.gz
URL=https://github.com/mobile-shell/mosh/releases/download/mosh-${VERSION}/${TARBALL}

here=$(cd "$(dirname "$0")" && pwd)
work=${WORK:-$HOME/.cache/mosh-termux}
mkdir -p "$work"

if command -v pkg >/dev/null 2>&1 && [ -n "${PREFIX:-}" ]; then
    termux=yes
    echo "==> dependencies (Termux)"
    pkg install -y build-essential autoconf automake libtool pkg-config \
        protobuf openssl ncurses abseil-cpp perl >/dev/null
else
    termux=no
    echo "==> not Termux, assuming build dependencies are installed"
fi

cd "$work"
[ -f "$TARBALL" ] || curl -LfsS -o "$TARBALL" "$URL"
echo "${SHA256}  ${TARBALL}" | sha256sum -c -

rm -rf "mosh-${VERSION}"
tar xf "$TARBALL"
echo "==> patching"
patch -p1 -d "mosh-${VERSION}" < "$here/patches/0001-terminaldisplay-replay-nested-mouse-modes.patch"

cd "mosh-${VERSION}"
echo "==> configure"
# -std=c++17 matches what the Termux mosh package uses: abseil, pulled in as a
# protobuf dependency, does not build as C++11.
./configure --prefix="${PREFIX:-/usr/local}" CXXFLAGS="-std=c++17 -O2" >/dev/null
echo "==> make"
make -j"$(nproc)" >/dev/null
built="$PWD/src/frontend/mosh-client"
echo "built: $built"

if [ "${1:-}" = "--install" ]; then
    if [ "$termux" != yes ]; then
        echo "--install is for Termux devices only; the binary is at $built" >&2
        exit 1
    fi
    echo "==> installing"
    [ -f "$PREFIX/bin/mosh-client.orig" ] || cp -a "$PREFIX/bin/mosh-client" "$PREFIX/bin/mosh-client.orig"
    install -m 0755 "$built" "$PREFIX/bin/mosh-client"
    apt-mark hold mosh
    echo "installed. stock binary kept at \$PREFIX/bin/mosh-client.orig"
    echo "mosh is now held; \"apt-mark unhold mosh\" to undo."
fi
