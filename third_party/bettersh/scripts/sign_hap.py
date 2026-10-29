#!/usr/bin/env python3
"""Sign a HAP with DevEco-generated material (~/.ohos/config).

Reads build-profile.json5 (material paths + DevEco-encrypted passwords),
translates C:\\... to /mnt/c/..., decrypts passwords with scripts/sign.js
(AES-128-GCM key derived from the material/ dir next to the cert), then invokes
hap-sign-tool.jar.

Usage: sign_hap.py <sign-config.json5> <in.hap> <out.hap> [signingConfigName]

signingConfigName 省略时沿用 signingConfigs[0]（DevEco 的 debug 材料）；发布包要传
`release`，因为那份 build-profile.json5 里第一条是调试证书、第二条才是发布证书。
"""
import json, os, re, subprocess, sys
from pathlib import Path

if len(sys.argv) not in (4, 5):
    print("usage: sign_hap.py <sign-config.json5> <in.hap> <out.hap> [signingConfigName]",
          file=sys.stderr)
    sys.exit(2)

sign_config, in_hap, out_hap = sys.argv[1:4]
want_name = sys.argv[4] if len(sys.argv) == 5 else None
script_dir = Path(__file__).resolve().parent


def win_to_wsl(p: str) -> str:
    m = re.match(r'^([A-Za-z]):[\\/](.*)$', p)
    if not m:
        return p
    drive, rest = m.group(1).lower(), m.group(2).replace('\\', '/')
    return f'/mnt/{drive}/{rest}'


with open(sign_config, encoding='utf-8') as f:
    content = f.read()
content = re.sub(r'//.*$', '', content, flags=re.MULTILINE)   # strip comments
content = re.sub(r',\s*([}\]])', r'\1', content)              # trailing commas
configs = json.loads(content)["app"]["signingConfigs"]

if want_name is None:
    cfg = configs[0]["material"]
else:
    hit = [c for c in configs if c.get("name") == want_name]
    if not hit:
        names = ", ".join(c.get("name", "?") for c in configs)
        print(f"error: no signingConfig named {want_name!r} (available: {names})",
              file=sys.stderr)
        sys.exit(2)
    cfg = hit[0]["material"]

cfg["certpath"] = win_to_wsl(cfg["certpath"])
cfg["profile"] = win_to_wsl(cfg["profile"])
cfg["storeFile"] = win_to_wsl(cfg["storeFile"])

base = Path(cfg["certpath"]).parent
if not (base / "material").is_dir():
    print(f"error: material/ not found next to {cfg['certpath']}", file=sys.stderr)
    sys.exit(1)


def decrypt(pwd: str) -> str:
    r = subprocess.run(
        ["node", str(script_dir / "sign.js"), str(base.absolute()), pwd],
        capture_output=True, text=True, check=True)
    return r.stdout.strip()


key_pwd = decrypt(cfg["keyPassword"])
store_pwd = decrypt(cfg["storePassword"])
if not key_pwd or not store_pwd:
    print("error: password decryption returned empty", file=sys.stderr)
    sys.exit(1)

jar = os.environ.get("HAP_SIGN_JAR",
                     "/apps/harmony/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar")
cmd = [
    "java", "-jar", jar, "sign-app",
    "-keyAlias",     cfg["keyAlias"],
    "-signAlg",      cfg["signAlg"],
    "-mode",         "localSign",
    "-appCertFile",  cfg["certpath"],
    "-profileFile",  cfg["profile"],
    "-inFile",       in_hap,
    "-keystoreFile", cfg["storeFile"],
    "-outFile",      out_hap,
    "-keyPwd",       key_pwd,
    "-keystorePwd",  store_pwd,
]
redacted = [("***" if a in (key_pwd, store_pwd) else a) for a in cmd]
print("+", " ".join(redacted))
sys.exit(subprocess.call(cmd))
