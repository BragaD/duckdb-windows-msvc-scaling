#!/usr/bin/env python3
"""Opt a Windows executable into the Segment Heap by patching its embedded
manifest in place (size-preserving), writing `<name>-sh.exe` next to the input.

    python patch_segment_heap.py path/to/duckdb.exe

If the exe has no embedded manifest (e.g. some MinGW builds), don't patch:
drop an external `duckdb.exe.manifest` next to it instead (see
`duckdb.exe.manifest` in this repo) - the loader honors it in that case.

The patch keeps the manifest resource the same size by padding with trailing
spaces (valid XML whitespace), so no PE/resource offsets change. If the
existing manifest is too small to fit the heapType element, it is replaced by
a minimal manifest containing only the heapType setting; if even that does
not fit, the script bails out (use mt.exe from the Windows SDK instead).
"""
import os
import re
import sys

HEAP = ("<heapType xmlns='http://schemas.microsoft.com/SMI/2020/WindowsSettings'>"
        "SegmentHeap</heapType>")
APP_BLOCK = ("<application xmlns='urn:schemas-microsoft-com:asm.v3'>"
             "<windowsSettings>" + HEAP + "</windowsSettings></application>")
MINIMAL = ("<assembly xmlns='urn:schemas-microsoft-com:asm.v1' manifestVersion='1.0'>"
           + APP_BLOCK + "</assembly>")


def main(path):
    data = bytearray(open(path, "rb").read())
    anchor = data.find(b"manifestVersion")
    if anchor == -1:
        sys.exit("no embedded manifest found - use an external '<exe>.manifest' "
                 "next to the exe instead (see duckdb.exe.manifest)")
    i = data.rfind(b"<assembly", 0, anchor)
    j = data.find(b"</assembly>", anchor) + len(b"</assembly>")
    if i == -1 or j < len(b"</assembly>"):
        sys.exit("malformed embedded manifest")
    old = data[i:j].decode("utf-8", "replace")
    old_len = j - i
    if "SegmentHeap" in old:
        sys.exit("manifest already opts into SegmentHeap")
    if "</windowsSettings>" in old:
        new = old.replace("</windowsSettings>", HEAP + "</windowsSettings>", 1)
    else:
        new = old.replace("</assembly>", APP_BLOCK + "</assembly>", 1)
    # reclaim space if needed: drop supportedOS entries and XML comments,
    # then fall back to a minimal heapType-only manifest
    while len(new) > old_len and "<supportedOS" in new:
        new = re.sub(r"\s*<supportedOS[^>]*/>", "", new, count=1)
    while len(new) > old_len and "<!--" in new:
        new = re.sub(r"\s*<!--.*?-->", "", new, count=1, flags=re.S)
    if len(new) > old_len:
        new = MINIMAL
    if len(new) > old_len:
        sys.exit(f"no room: need {len(new)} bytes, manifest has {old_len} - "
                 "re-embed with mt.exe from the Windows SDK instead")
    out = os.path.splitext(path)[0] + "-sh.exe"
    data[i:j] = new.encode() + b" " * (old_len - len(new))
    open(out, "wb").write(bytes(data))
    print(f"wrote {out} (manifest {len(new)} bytes, padded to {old_len})")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
