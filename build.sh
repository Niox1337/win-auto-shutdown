#!/bin/sh
# Builds dist/熄屏自动关机.zip containing the user-facing files in a 熄屏自动关机 folder.
# Entry names are stored as UTF-8 with the UTF-8 name flag set, which Windows needs to show Chinese names.
set -e
cd "$(dirname "$0")"
out="${1:-dist}"
rm -rf "$out"
mkdir -p "$out"
python3 - "$out/熄屏自动关机.zip" <<'PY'
import sys, zipfile
folder = "熄屏自动关机"
files = ["熄屏自动关机.ps1", "安装.cmd", "卸载.cmd", "使用说明.txt"]
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr(zipfile.ZipInfo(folder + "/"), b"")
    for name in files:
        z.write(name, folder + "/" + name)
for info in zipfile.ZipFile(sys.argv[1]).infolist():
    if any(ord(c) > 127 for c in info.filename) and not info.flag_bits & 0x800:
        sys.exit("entry without the UTF-8 name flag: " + info.filename)
    print(info.filename)
PY
