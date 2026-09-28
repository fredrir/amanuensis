#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
identity = sys.argv[2] or "-"
entitlements = Path(__file__).resolve().parents[1] / "backend/Backend.entitlements"
magics = {
    b"\xcf\xfa\xed\xfe",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
}
executables = {"python3.12", "python3", "node", "codex", "codex-code-mode-host"}

for path in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
    if path.is_symlink() or not path.is_file():
        continue
    with path.open("rb") as stream:
        if stream.read(4) not in magics:
            continue
    command = [
        "codesign",
        "--force",
        "--sign",
        identity,
        "--options",
        "0" if identity == "-" else "runtime",
    ]
    command.append("--timestamp=none" if identity == "-" else "--timestamp")
    if path.name in executables:
        command.extend(["--entitlements", str(entitlements)])
    subprocess.run(
        [*command, str(path)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
