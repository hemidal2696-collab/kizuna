#!/usr/bin/env python3
# Kizuna for iOS/iPadOS - patches applied to the pinned chiaki-ng checkout.
# SPDX-License-Identifier: AGPL-3.0-only
#
# Usage: python3 patch_chiaki.py <chiaki-ng source dir>
#
# Every patch is an exact string replacement with an expected occurrence count,
# so an upstream change makes the build fail loudly instead of silently
# producing a broken library. Re-running is a no-op (a marker file is written).
#
# 1. Root CMakeLists.txt: chiaki FORCEs CMAKE_OSX_DEPLOYMENT_TARGET to a macOS
#    version for every Apple build. Restrict that to macOS (NOT IOS) so our
#    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 survives.
# 2. lib/CMakeLists.txt: skip the libevent lookup on iOS (no libevent there).
# 3. lib/src/remote/holepunch.c: on Apple platforms use the select() candidate
#    loop that chiaki already uses on Android instead of libevent.
#    FD_SETSIZE is 1024 on iOS, far above the sockets holepunch opens.
# 4. patches/*.patch (git apply): fixes taken from later chiaki-ng commits.
#    chiaki-feedback-history.patch = upstream 698e0ec, 4382c1c, bfbb296, c938844
#    (Oct 2026): one controller event per feedback packet, event count in the
#    header, the last 8 events repeated and the newest packet resent at +20, 50,
#    100 and 200 ms, so a button release lost to packet loss no longer leaves
#    the button held, and L2+R2 pressed together both register.

import pathlib
import subprocess
import sys

MARKER = ".kizuna-patched"


def replace(path: pathlib.Path, old: str, new: str, count: int) -> None:
    text = path.read_text(encoding="utf-8")
    found = text.count(old)
    if found != count:
        sys.exit(f"patch_chiaki: expected {count} occurrence(s) of {old!r} in {path}, found {found}")
    path.write_text(text.replace(old, new), encoding="utf-8", newline="\n")
    print(f"patch_chiaki: patched {path.name} ({count}x)")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: patch_chiaki.py <chiaki-ng dir>")
    root = pathlib.Path(sys.argv[1]).resolve()
    marker = root / MARKER
    if marker.exists():
        print("patch_chiaki: already patched")
        return

    replace(root / "CMakeLists.txt",
            'if(APPLE)\n\tif(CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "arm64")',
            'if(APPLE AND NOT IOS)\n\tif(CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "arm64")',
            1)

    replace(root / "lib" / "CMakeLists.txt",
            "if(NOT CHIAKI_IS_SWITCH AND NOT CHIAKI_ENABLE_ANDROID)",
            "if(NOT CHIAKI_IS_SWITCH AND NOT CHIAKI_ENABLE_ANDROID AND NOT IOS)",
            1)

    hp = root / "lib" / "src" / "remote" / "holepunch.c"
    replace(hp,
            "#include <assert.h>\n",
            "#include <assert.h>\n#ifdef __APPLE__\n#include <sys/select.h>\n#endif\n",
            1)
    replace(hp,
            "#if !defined(__SWITCH__) && !defined(__ANDROID__)\n",
            "#if !defined(__SWITCH__) && !defined(__ANDROID__) && !defined(__APPLE__)\n",
            5)
    replace(hp,
            "#ifdef __ANDROID__\n    fd_set fds;",
            "#if defined(__ANDROID__) || defined(__APPLE__)\n    fd_set fds;",
            1)
    replace(hp,
            "#elif defined(__ANDROID__)\n",
            "#elif defined(__ANDROID__) || defined(__APPLE__)\n",
            1)

    for patch in sorted((pathlib.Path(__file__).resolve().parent / "patches").glob("*.patch")):
        subprocess.run(["git", "-C", str(root), "apply", "--whitespace=nowarn", str(patch)], check=True)
        print(f"patch_chiaki: applied {patch.name}")

    marker.write_text("patched by Kizuna ios/scripts/patch_chiaki.py\n", encoding="utf-8")


if __name__ == "__main__":
    main()
