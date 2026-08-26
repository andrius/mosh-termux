# mosh-termux

[![ci](https://github.com/andrius/mosh-termux/actions/workflows/ci.yml/badge.svg)](https://github.com/andrius/mosh-termux/actions/workflows/ci.yml)

A one-hunk patch to `mosh-client` that restores mouse support for
crossterm-based TUIs - zellij, gitui, bottom, and most Rust terminal apps -
when mosh is used from Termux on Android.

Upstream bug: [mosh#1364](https://github.com/mobile-shell/mosh/issues/1364)
(open since 2025-12-09).

## Quick start

Three commands on the device, then `mosh` behaves:

```bash
curl -fsSL https://andrius.github.io/mosh-termux/mosh-termux.gpg \
  -o $PREFIX/etc/apt/trusted.gpg.d/mosh-termux.gpg
echo "deb [signed-by=$PREFIX/etc/apt/trusted.gpg.d/mosh-termux.gpg] https://andrius.github.io/mosh-termux stable main" \
  > $PREFIX/etc/apt/sources.list.d/mosh-termux.list
pkg update && pkg install mosh
```

Signed repository, four Termux architectures, built by CI in the official Termux
builder image. Details, the pin you probably also want, and the single-`.deb`
route are further down. What follows first is why any of this is necessary.

## Symptom

| Path | Mouse |
|---|---|
| Termux -> ssh -> zellij | works |
| Termux -> mosh -> zellij | dead |
| macOS or Linux -> mosh -> zellij | works |

Keyboard, rendering and roaming are all fine. Only pointer input is lost, and
only in the Termux + mosh combination.

## Root cause

Two individually defensible behaviours that break as a pair.

**1. Applications ask for mouse reporting redundantly.** crossterm
`EnableMouseCapture` writes five private modes in a single burst:

```
ESC[?1000h ESC[?1002h ESC[?1003h ESC[?1015h ESC[?1006h
```

This is deliberate. A terminal is expected to latch the strongest mode it
implements and silently ignore the rest.

**2. mosh does not forward bytes, it re-renders state.** `mosh-server` runs a
real terminal emulator and ships the resulting screen state to the client.
`src/terminal/terminalfunctions.cc:CSI_DECSM` collapses that whole class of
modes into a single scalar:

```c
if (param == 9 || (param >= 1000 && param <= 1003)) {
  fb->ds.mouse_reporting_mode = (Terminal::DrawState::MouseReportingMode) param;
} else if (param == 1005 || param == 1006 || param == 1015) {
  fb->ds.mouse_encoding_mode = (Terminal::DrawState::MouseEncodingMode) param;
}
```

Last one wins. The intermediate `1000h` and `1002h` never exist as state, so
they never reach the wire. `terminaldisplay.cc` then re-emits exactly one
reporting mode and one encoding mode: `ESC[?1003h ESC[?1006h`.

**3. Termux does not implement 1003.** In the Termux APK,
`TerminalEmulator.mapDecSetBitToInternalBit()` handles 1000, 1002, 1004, 1006
and 2004. Modes 9, 1001, 1003, 1005 and 1015 return `-1` and are dropped
without a trace. `isMouseTrackingActive()` stays false, so `TerminalView` never
turns a tap into a mouse report.

So mosh strips exactly the redundancy Termux depends on. Over plain ssh all
five requests arrive verbatim, Termux latches 1002, and the mouse works. On
macOS and Linux the terminal implements 1003, so mosh's normalised output is
fine. Termux plus mosh is the only combination where both halves misalign.

Formally the defect is in Termux - 1003 has been in xterm since the 1990s, and
it is still unimplemented on `termux-app` master, so waiting for a Termux
release does not help. But mosh is the cheaper place to fix it, and mosh is
also doing something actively harmful (see below), so that is what this repo
patches.

## Measurements

`mosh-server` and `mosh-client` were run over loopback on the device, capturing
what the client writes to its terminal.

| Case | Termux receives | Result |
|---|---|---|
| zellij through mosh | `1003h 1006h` | dead |
| tmux `mouse on` through mosh | `1002h 1006h` | works |
| tmux, then a pane app asks for 1003 | `1002h 1006h` ... `1002l 1003h` | dies mid-session |

Row three is the second half of the bug: on a mode change mosh explicitly
disables the previous mode before setting the new one, so a session whose mouse
was working loses it the moment something requests all-motion tracking.

The input direction is not involved. SGR (`ESC[<0;10;5M`) and legacy X10
(`ESC[M` plus three bytes) mouse reports both cross a mosh link byte for byte.

After the patch, measured the same way on the same device:

| Case | Termux receives | Result |
|---|---|---|
| zellij through mosh | `1000h 1002h 1003h 1006h` | works |
| tmux, then a pane app asks for 1003 | `1000h 1002h 1006h` ... `1000h 1002h 1003h` | survives |

The `1002l` that killed a live session is gone, and 1002 is now always latched
before the mode Termux cannot use.

## The fix

`patches/0001-terminaldisplay-replay-nested-mouse-modes.patch` changes
`mosh-client` to replay the nested ladder weakest-first instead of emitting the
single collapsed mode, and drops the explicit disable of the previous mode.

Modes 1000, 1002 and 1003 are strictly nested and share one variable in xterm
just as they do in mosh, so the last request still wins: on a terminal that
implements all three, behaviour is unchanged. On a terminal that implements
only some, the strongest supported rung stays latched.

The collapse happens on the server, but the information is recoverable on the
client, so **only the phone needs the patched binary**. Servers keep stock
`mosh-server`, the wire format is untouched, and there is no version skew.

Dropping the explicit disable is a tidy-up, not a second fix. It is what killed a
running session in unpatched mosh, but once the ladder is in place the disable is
merely redundant: it is emitted first and the ladder immediately re-establishes
state from the bottom.

### Relationship to upstream

[mosh#1405](https://github.com/mobile-shell/mosh/pull/1405), open since
2026-08-22, fixes this the same way - it announces the lower modes alongside the
stored one and keeps the disable. Its thresholds differ from this patch only for
mode 1001, which nothing uses. When it lands and reaches Termux, this repository
has no reason to exist; until then it is the same fix, shipped.

## Install from the apt repository

CI builds a real `mosh` package for every Termux architecture in the official
Termux builder image and publishes a signed apt repository, so nothing has to be
compiled on the phone:

```bash
curl -fsSL https://andrius.github.io/mosh-termux/mosh-termux.gpg \
  -o $PREFIX/etc/apt/trusted.gpg.d/mosh-termux.gpg
echo "deb [signed-by=$PREFIX/etc/apt/trusted.gpg.d/mosh-termux.gpg] https://andrius.github.io/mosh-termux stable main" \
  > $PREFIX/etc/apt/sources.list.d/mosh-termux.list
pkg update && pkg install mosh
```

The repository and its landing page are published to GitHub Pages by CI on every
`v*` tag, and each deploy replaces the previous one, so the index never carries
packages that are no longer there.

The repository is signed. Key fingerprint:

```
683C B53B C7FD A175 571D  D268 9D26 0699 36D0 F390
```

Packages carry a `.1` revision suffix on top of the official Termux revision, so
apt sees an ordinary upgrade. The flip side: if Termux later ships a mosh
revision newer than the one this repository was last built against, the stock
package wins again and the fix disappears without a word. To stop that:

```bash
cat > $PREFIX/etc/apt/preferences.d/mosh-termux <<'EOF'
Package: mosh mosh-perl
Pin: release o=mosh-termux
Pin-Priority: 1001
EOF
```

The pin keeps you on this repository's mosh until it is rebuilt, so if it falls
behind upstream Termux, open an issue.

## Install a single .deb

Every [release](https://github.com/andrius/mosh-termux/releases) attaches the
same packages as plain files. `dpkg --print-architecture` tells you which one to
take, and `mosh-perl_*.deb` is the optional perl wrapper, needed only if you
already had `mosh-perl` installed:

```bash
curl -LO https://github.com/andrius/mosh-termux/releases/latest/download/mosh_<version>_<arch>.deb
dpkg -i ./mosh_<version>_<arch>.deb
```

## Build it yourself

On the device:

```bash
git clone https://github.com/andrius/mosh-termux ~/mosh-termux
cd ~/mosh-termux
bash build.sh --install
```

`build.sh` fetches the upstream `mosh-1.4.0` release tarball, checks its
sha256, applies the patch and builds. `--install` keeps the stock binary at
`$PREFIX/bin/mosh-client.orig`, installs the patched one, and runs
`apt-mark hold mosh` so an upgrade cannot silently replace it.

To undo:

```bash
apt-mark unhold mosh
apt install --reinstall mosh
```

## Verify

From a real Termux session, not over ssh - `script(1)` needs a pty with a
nonzero size:

```bash
bash verify.sh
```

It drives a loopback mosh session where the far end requests the crossterm
burst, and prints which modes the client passed on. Stock prints `1003h 1006h`
and fails; patched prints `1000h 1002h 1003h 1006h` and passes.

Then confirm by hand, since no automated check can tap a screen: open a mosh
session, start zellij, and tap a pane.

Confirmed on hardware 2026-08-26: Galaxy Fold7, Android 16, aarch64,
Termux 0.118.3, against a stock `mosh-server` 1.4.0.

## Notes

- The Termux `mosh` package is stock upstream 1.4.0. Its only two patches
  rewrite paths (motd location, `SHELL=$PREFIX/bin/sh`); nothing touches
  terminal emulation. The binary behaves exactly like Debian's.
- The terminal emulator is not part of that package. It is Java inside the
  Termux APK, `terminal-emulator/src/main/java/com/termux/terminal/TerminalEmulator.java`.
- Workaround without building anything: run zellij inside tmux with
  `set -g mouse on`. tmux enables 1002 first, Termux latches it, and the
  session keeps its mouse.

## Licence

The patch modifies [mosh](https://github.com/mobile-shell/mosh), which is
GPL-3.0-or-later, so it carries the same terms. The scripts in this repository
are offered under GPL-3.0-or-later as well, to keep the whole thing one licence.
