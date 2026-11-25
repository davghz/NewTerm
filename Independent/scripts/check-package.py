#!/usr/bin/env python3
import argparse
import hashlib
import pathlib
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description="Check identity and contents of a completed t3rm Debian package")
parser.add_argument("deb", type=pathlib.Path)
parser.add_argument("variant", choices=["production", "review"])
args = parser.parse_args()
deb = args.deb.resolve()
bundle = "com.davghz.t3rm" + (".review" if args.variant == "review" else "")
url_scheme = "t3rm-review-ssh" if args.variant == "review" else "t3rm-ssh"
app_name = bundle if args.variant == "review" else "t3rm"

def require(condition, message):
    if not condition:
        raise SystemExit(message)

def output(*command):
    return subprocess.check_output(command).decode().strip()

digest = hashlib.sha256(deb.read_bytes()).hexdigest()
require(deb.with_name(deb.name + ".sha256").read_text().split() == [digest, deb.name], "Bad package checksum")
for field, value in {"Package": bundle, "Architecture": "iphoneos-arm64", "Version": "0.2.0~alpha2"}.items():
    require(output("dpkg-deb", "-f", str(deb), field) == value, f"Wrong Debian {field}")
with tempfile.TemporaryDirectory() as scratch:
    root = pathlib.Path(scratch)
    subprocess.run(["dpkg-deb", "-x", str(deb), scratch], check=True)
    app = root / "var" / "jb" / "Applications" / (app_name + ".app")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == bundle, "Bundle identifier mismatch")
    require(info["MinimumOSVersion"] == "15.1.1", "Deployment target mismatch")
    require(info["CFBundleVersion"] == "5" and info["CFBundleShortVersionString"] == "0.2.0", "Build version mismatch")
    require(set(info["UIDeviceFamily"]) == {1,2}, "Missing iPhone/iPad support")
    require(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == [url_scheme], "URL scheme collision")
    for name in ["t3rm", "T3ShellLauncher"]:
        path = app / name
        require(output("lipo", "-archs", str(path)) == "arm64", f"Wrong architecture for {name}")
        build = output("xcrun", "vtool", "-show-build", str(path)).split()
        require("IOS" in build and "15.1.1" in build, f"Wrong platform for {name}")
        libraries = output("otool", "-L", str(path))
        require(all(word not in libraries for word in ["SwiftTerm","SwiftUIX","NewTerm"]), f"Legacy linkage in {name}")
    require((app / "Assets.car").is_file() and (app / "RIGHTS.txt").is_file(), "Artwork or rights notice missing")
    require(all("newterm" not in p.name.lower() for p in root.rglob("*")), "Legacy file in independent package")
    require((app / "ShellStartup" / ".zshenv").is_file(), "Missing app-scoped zsh startup")
    require(all((app / name).stat().st_mode & 0o111 for name in ["t3rm","T3ShellLauncher"]), "Non-executable package payload")
    entitlements = plistlib.loads(subprocess.check_output(["ldid", "-e", str(app / "t3rm")]))
    require(entitlements == {"com.apple.private.security.no-container": True}, "Unexpected app entitlements")
print(f"{bundle} {digest} verified")
