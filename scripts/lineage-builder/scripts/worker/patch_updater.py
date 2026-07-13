#!/usr/bin/env python3
import sys
import re

if len(sys.argv) < 3:
    print("Usage: patch_updater.py <makefile> <uri>")
    sys.exit(1)

makefile = sys.argv[1]
uri = sys.argv[2]

with open(makefile, "r") as f:
    content = f.read()

pattern = r"lineage\.updater\.uri\s*=\s*\S+"
if re.search(pattern, content):
    new_content = re.sub(pattern, f"lineage.updater.uri={uri}", content)
else:
    new_content = content
    if not new_content.endswith("\n"):
        new_content += "\n"
    new_content += (
        f"\nPRODUCT_SYSTEM_DEFAULT_PROPERTIES += \\\n    lineage.updater.uri={uri}\n"
    )

with open(makefile, "w") as f:
    f.write(new_content)
