#!/usr/bin/env python3
"""Print the crashing thread of the newest iPad crash report for a process.

usage: crash.py <process name> [udid]
"""
import json, os, re, subprocess, sys, tempfile

name = sys.argv[1]
udid = sys.argv[2] if len(sys.argv) > 2 else os.environ["UDID"]
listing = subprocess.run(["xcrun", "devicectl", "device", "info", "files", "--device", udid,
                          "--domain-type", "systemCrashLogs"], capture_output=True, text=True).stdout
reports = sorted(re.findall(rf"^({re.escape(name)}-\S+\.ips)", listing, re.M))
if not reports:
    sys.exit("no crash report")
dest = os.path.join(tempfile.mkdtemp(), "crash.ips")
subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", udid, "--domain-type", "systemCrashLogs",
                "--source", reports[-1], "--destination", dest], capture_output=True)
d = json.loads(open(dest).read().split("\n", 1)[1])
ex = d.get("exception", {})
print(f"{reports[-1]}: {ex.get('type')} {ex.get('subtype', '')} {d.get('asi', '')}".strip())
images = d["usedImages"]
for t in d["threads"]:
    if t.get("triggered"):
        for f in t["frames"][:30]:
            im = images[f["imageIndex"]].get("name", "?")
            print(f"  {im:32} {f.get('symbol', '?')}+{f.get('symbolLocation', 0)}  (0x{f['imageOffset']:x})")
