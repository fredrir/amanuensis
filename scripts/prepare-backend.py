#!/usr/bin/env python3
import argparse
import hashlib
import json
import platform
import runpy
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BACKEND = REPO / "backend"
STAGING = REPO / "build/backend"
NODE_VERSION = "v24.21.0"


def run(*args, **kwargs):
    subprocess.run(args, cwd=REPO, check=True, **kwargs)


def copy_tree(source, target):
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(
        source,
        target,
        symlinks=True,
        ignore=shutil.ignore_patterns("__pycache__", ".cache", ".DS_Store"),
    )


def prepare(development):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        sys.exit("ScreenScribe requires Apple Silicon.")
    run("uv", "sync", "--project", str(BACKEND), "--locked")
    fingerprint = hashlib.sha256(
        (BACKEND / "clients/package-lock.json").read_bytes()
    ).hexdigest()
    marker = BACKEND / "clients/node_modules/.screenscribe-lock"
    if not marker.exists() or marker.read_text() != fingerprint:
        run(
            "npm",
            "ci",
            "--prefix",
            str(BACKEND / "clients"),
            "--ignore-scripts",
            "--no-audit",
            "--no-fund",
        )
        marker.write_text(fingerprint)
    model = BACKEND / "models/ibm-granite--granite-docling-258M-mlx"
    model_revision = runpy.run_path(
        str(BACKEND / "src/screen_scribe_backend/config.py")
    )["MODEL_REVISION"]
    if (
        not (model / "REVISION").exists()
        or (model / "REVISION").read_text().strip() != model_revision
        or not (model / "model.safetensors").exists()
    ):
        run(
            "uv",
            "run",
            "--project",
            str(BACKEND),
            "--locked",
            "python",
            "-m",
            "screen_scribe_backend.download_model",
        )
    if development:
        return
    STAGING.mkdir(parents=True, exist_ok=True)
    dependency_hash = hashlib.sha256((BACKEND / "uv.lock").read_bytes()).hexdigest()
    dependency_marker = STAGING / ".dependencies"
    if (
        not dependency_marker.exists()
        or dependency_marker.read_text() != dependency_hash
    ):
        requirements = REPO / "build/backend-requirements.txt"
        run(
            "uv",
            "export",
            "--project",
            str(BACKEND),
            "--locked",
            "--no-dev",
            "--no-editable",
            "--no-emit-project",
            "--output-file",
            str(requirements),
            stdout=subprocess.DEVNULL,
        )
        packages = STAGING / "site-packages"
        if packages.exists():
            shutil.rmtree(packages)
        run(
            "uv",
            "pip",
            "install",
            "--python",
            str(BACKEND / ".venv/bin/python3"),
            "--target",
            str(packages),
            "--no-deps",
            "--requirements",
            str(requirements),
        )
        runtime = subprocess.check_output(
            [
                str(BACKEND / ".venv/bin/python3"),
                "-c",
                "import sys; print(sys.base_prefix)",
            ],
            text=True,
        ).strip()
        copy_tree(Path(runtime), STAGING / "python")
        dependency_marker.write_text(dependency_hash)
    copy_tree(BACKEND / "src", STAGING / "src")
    copy_tree(BACKEND / "models", STAGING / "models")
    copy_tree(BACKEND / "licenses", STAGING / "licenses")
    copy_tree(BACKEND / "clients/node_modules", STAGING / "clients/node_modules")
    # Voice, terminals and shell tools are not part of image extraction.
    codex = (
        STAGING
        / "clients/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin"
    )
    for folder in ("codex-resources", "codex-path"):
        shutil.rmtree(codex / folder, ignore_errors=True)
    if not (STAGING / "node/bin/node").exists():
        archive_name = f"node-{NODE_VERSION}-darwin-arm64.tar.gz"
        base = f"https://nodejs.org/dist/{NODE_VERSION}/"
        archive = REPO / "build" / archive_name
        urllib.request.urlretrieve(base + archive_name, archive)
        checksums = urllib.request.urlopen(base + "SHASUMS256.txt").read().decode()
        expected = next(
            line.split()[0]
            for line in checksums.splitlines()
            if line.split()[-1] == archive_name
        )
        if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
            sys.exit("Node archive checksum mismatch.")
        with tarfile.open(archive) as compressed:
            compressed.extractall(REPO / "build", filter="data")
        shutil.move(
            str(REPO / "build" / archive_name.removesuffix(".tar.gz")), STAGING / "node"
        )
    manifest = {
        "python": "3.12",
        "node": NODE_VERSION,
        "providers": json.loads((BACKEND / "clients/package.json").read_text())[
            "dependencies"
        ],
    }
    (STAGING / "runtime.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--development", action="store_true")
    prepare(parser.parse_args().development)
