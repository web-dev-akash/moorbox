#!/bin/bash
# Writes the license and NOTICE texts of every resolved Swift package dependency, plus the
# vendored Android proto, into one file that ships inside Moorbox.app
# (Contents/Resources/ThirdPartyLicenses.txt). Apache-2.0 §4 requires these notices.
#   scripts/collect-licenses.sh <output-file>
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?output file}"
swift package resolve >/dev/null
python3 -I - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
pins = json.load(open("Package.resolved"))["pins"]
rule = "-" * 78
lines = [
    "Moorbox third-party licenses\n============================\n",
    "Moorbox is licensed under the Apache License 2.0 (see LICENSE). It includes the\n"
    "following third-party software, under the licenses reproduced below.\n",
    rule,
    "Android Emulator gRPC API (Proto/emulator_controller.proto and code generated from it)\n"
    "Copyright (C) 2018 The Android Open Source Project. Apache License 2.0.\n"
    "Source: https://android.googlesource.com/platform/external/qemu\n",
]
for p in sorted(pins, key=lambda p: p["identity"]):
    name = p["identity"]
    version = p["state"].get("version") or p["state"].get("revision", "")[:12]
    root = os.path.join(".build", "checkouts", name)
    if not os.path.isdir(root):
        sys.exit(f"missing checkout for {name}; run `swift package resolve`")
    files = sorted(f for f in os.listdir(root) if f.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE")))
    if not any(f.upper().startswith(("LICENSE", "LICENCE", "COPYING")) for f in files):
        sys.exit(f"no license file found for {name}")
    lines += [rule, f"{name} {version}\n{p['location']}\n"]
    for f in files:
        text = open(os.path.join(root, f), encoding="utf-8", errors="replace").read().rstrip()
        lines += [f"--- {f} ---\n", text + "\n"]
open(out, "w").write("\n".join(lines))
print(f"wrote {out}: {len(pins)} packages")
PY
