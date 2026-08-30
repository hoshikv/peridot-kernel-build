#!/usr/bin/env python3
import re
import sys
import os

CONFIGS = os.path.join(sys.argv[1], "arch", "arm64", "configs", "vendor")
BASE = sys.argv[2]

FRAGMENTS = []
for name in os.listdir(CONFIGS):
    if "peridot" in name or name.startswith("pineapple"):
        FRAGMENTS.append(os.path.join(CONFIGS, name))

if not FRAGMENTS:
    print("no vendor fragment found", file=sys.stderr)
    sys.exit(1)

lines = []
for frag in FRAGMENTS:
    with open(frag) as fh:
        lines.extend(l.strip() for l in fh if l.strip() and not l.strip().startswith("#"))

merge = {}
for line in lines:
    m = re.match(r"(CONFIG_[A-Z0-9_]+)=(.*)", line)
    if m:
        merge[m.group(1)] = m.group(2)
    elif re.match(r"# CONFIG_[A-Z0-9_]+ is not set", line):
        m = re.match(r"# (CONFIG_[A-Z0-9_]+) is not set", line)
        merge[m.group(1)] = "n"

with open(BASE) as fh:
    base = fh.readlines()

out = []
written = set()
for line in base:
    m = re.match(r"(CONFIG_[A-Z0-9_]+)=", line)
    if m and m.group(1) in merge:
        v = merge.pop(m.group(1))
        if v == "n":
            continue
        out.append(f"{m.group(1)}={v}\n")
        written.add(m.group(1))
    elif re.match(r"# CONFIG_[A-Z0-9_]+ is not set", line) and v:
        pass
    else:
        out.append(line)

for k, v in merge.items():
    if v == "n":
        out.append(f"# {k} is not set\n")
    else:
        out.append(f"{k}={v}\n")

with open(BASE, "w") as fh:
    fh.writelines(out)

print(f"merged {len(written)} vendor config keys")