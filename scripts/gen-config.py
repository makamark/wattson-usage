#!/usr/bin/env python3
"""从 agg.config.json 生成 codeburn 的 devices.json（远端设备镜像根）。"""
import json
import os
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
cfg_path = Path(os.environ.get("AGG_CONFIG") or root / "agg.config.json")
out_path = Path(os.environ.get("CODEBURN_DEVICES_FILE")
                or Path.home() / ".config" / "codeburn" / "devices.json")

if not cfg_path.exists():
    sys.exit(f"config not found: {cfg_path}")
cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
devices = []
for d in cfg.get("devices", []):
    if d.get("local"):
        continue
    name = d["name"]
    devices.append({
        "host": name,
        "zcodeDb": f"~/codeburn-agg/mirror/{name}/zcode/db.sqlite",
        "codexHome": f"~/codeburn-agg/mirror/{name}/codex",
        "workbuddyDb": f"~/codeburn-agg/mirror/{name}/workbuddy/db.sqlite",
    })
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(json.dumps(devices, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"wrote {out_path} ({len(devices)} remote device(s))")
