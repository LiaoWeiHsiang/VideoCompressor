#!/usr/bin/env python3
"""Convert Simplified Chinese *string literals* to Traditional (Taiwan) in-place.

Only string literals are touched. Comments are left alone deliberately: they are not
user-visible, and keeping them byte-identical to upstream makes the vendored patch set
reviewable and future upstream merges tractable.
"""
import re, subprocess, sys, pathlib

ROOTS = ["TimelineKitUIiOS", "TimelineKitUISharedViews", "TimelineKitUIShared",
         "TimelineKitCore", "TimelineKitRender"]
CJK = re.compile(r'[一-鿿]')
STRLIT = re.compile(r'"([^"\\]*(?:\\.[^"\\]*)*)"')

base = pathlib.Path(sys.argv[1])
files = [p for r in ROOTS for p in sorted((base / r).rglob("*.swift"))]

# Collect every distinct literal first, so opencc runs once instead of thousands of times.
originals = []
seen = set()
for p in files:
    for line in p.read_text(encoding="utf8").splitlines():
        s = line.strip()
        if s.startswith(("//", "///", "*")):
            continue
        for m in STRLIT.finditer(line):
            body = m.group(1)
            if CJK.search(body) and body not in seen:
                seen.add(body)
                originals.append(body)

if not originals:
    print("nothing to convert")
    sys.exit(0)

converted = subprocess.run(
    ["opencc", "-c", "s2twp"],
    input="\n".join(originals), capture_output=True, text=True, check=True,
).stdout.split("\n")

assert len(converted) == len(originals), f"opencc returned {len(converted)} of {len(originals)} lines"
table = dict(zip(originals, converted))

changed_files = 0
changed_strings = 0
for p in files:
    lines = p.read_text(encoding="utf8").splitlines(keepends=True)
    out = []
    touched = False
    for line in lines:
        if line.strip().startswith(("//", "///", "*")) or not CJK.search(line):
            out.append(line)
            continue

        def repl(m):
            global changed_strings, touched
            body = m.group(1)
            new = table.get(body)
            if new is not None and new != body:
                changed_strings += 1
                touched = True
                return '"' + new + '"'
            return m.group(0)

        out.append(STRLIT.sub(repl, line))
    if touched:
        p.write_text("".join(out), encoding="utf8")
        changed_files += 1

print(f"converted {changed_strings} strings across {changed_files} files")
