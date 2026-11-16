#!/bin/sh
# Builds dist/win-auto-shutdown.zip containing the user-facing files in a win-auto-shutdown folder.
set -e
cd "$(dirname "$0")"
out="${1:-dist}"
rm -rf "$out"
mkdir -p "$out"
"${PYTHON:-python3}" - "$out/win-auto-shutdown.zip" <<'PY'
import sys, zipfile
folder = "win-auto-shutdown"
files = ["AutoShutdown.ps1", "Install.cmd", "Uninstall.cmd", "README.txt"]
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr(zipfile.ZipInfo(folder + "/"), b"")
    for name in files:
        z.write(name, folder + "/" + name)
for info in zipfile.ZipFile(sys.argv[1]).infolist():
    print(info.filename)
PY
