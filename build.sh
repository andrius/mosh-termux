#!/usr/bin/env bash
# Build a patched mosh-client. Run this ON the Termux device.
#
#   bash build.sh            # build only
#   bash build.sh --install  # build, then replace $PREFIX/bin/mosh-client
#
set -euo pipefail

VERSION=1.4.0
SHA256=872e4b134e5df29c8933dff12350785054d2fd2839b5ae6b5587b14db1465ddd
TARBALL=mosh-${VERSION}.tar.gz
URL=https://github.com/mobile-shell/mosh/releases/download/mosh-${VERSION}/${TARBALL}

here=$(cd "$(dirname "$0")" && pwd)
work=${WORK:-$HOME/.cache/mosh-termux}
mkdir -p "$work"

echo "==> dependencies"
pkg install -y build-essential autoconf automake libtool pkg-config \
    protobuf openssl ncurses abseil-cpp perl >/dev/null

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
./configure --prefix="$PREFIX" CXXFLAGS="-std=c++17 -O2" >/dev/null
echo "==> make"
make -j"$(nproc)" >/dev/null
built="$PWD/src/frontend/mosh-client"
echo "built: $built"

if [ "${1:-}" = "--install" ]; then
    echo "==> installing"
    [ -f "$PREFIX/bin/mosh-client.orig" ] || cp -a "$PREFIX/bin/mosh-client" "$PREFIX/bin/mosh-client.orig"
    install -m 0755 "$built" "$PREFIX/bin/mosh-client"
    apt-mark hold mosh
    echo "installed. stock binary kept at \$PREFIX/bin/mosh-client.orig"
    echo "mosh is now held; \"apt-mark unhold mosh\" to undo."
fi
