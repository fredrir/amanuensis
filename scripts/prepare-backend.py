#!/usr/bin/env python3
import argparse
import hashlib
import json
import platform
import re
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
GRANITE_STAGING = REPO / "build/granite"
GRANITE_MANIFEST = BACKEND / "granite-pack.json"
NODE_VERSION = "v24.21.0"
CONFIG = runpy.run_path(str(BACKEND / "src/amanuensis_backend/config.py"))


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


def remove(path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)


def requirements(*options):
    text = subprocess.check_output(
        [
            "uv",
            "export",
            "--project",
            str(BACKEND),
            "--locked",
            "--no-editable",
            "--no-emit-project",
            "--no-header",
            "--no-annotate",
            *options,
        ],
        cwd=REPO,
        text=True,
    )
    blocks = re.split(r"\n(?=\S)", text.strip())
    return {
        re.split(r"[=\s;]", block, maxsplit=1)[0].lower(): block for block in blocks
    }


def render(blocks):
    return "\n".join(blocks[name] for name in sorted(blocks)) + "\n"


def python_version():
    return subprocess.check_output(
        [
            str(BACKEND / ".venv/bin/python3"),
            "-c",
            "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')",
        ],
        text=True,
    ).strip()


def dependency_sets():
    base = requirements("--no-default-groups")
    granite = {
        name: block
        for name, block in requirements("--only-group", "granite").items()
        if name not in base
    }
    return base, granite


def granite_pack_id(granite):
    fingerprint = "\n".join(
        [
            render(granite),
            CONFIG["MODEL_ID"],
            CONFIG["MODEL_REVISION"],
            python_version(),
        ]
    )
    return hashlib.sha256(fingerprint.encode()).hexdigest()[:12]


def install(blocks, name, target):
    requirements_file = REPO / f"build/{name}-requirements.txt"
    requirements_file.parent.mkdir(parents=True, exist_ok=True)
    requirements_file.write_text(render(blocks))
    if target.exists():
        shutil.rmtree(target)
    run(
        "uv",
        "pip",
        "install",
        "--python",
        str(BACKEND / ".venv/bin/python3"),
        "--target",
        str(target),
        "--no-deps",
        "--requirements",
        str(requirements_file),
    )


def check_platform():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        sys.exit("Amanuensis requires Apple Silicon.")


def ensure_model():
    model = CONFIG["MODEL_PATH"]
    revision = model / "REVISION"
    if (
        not revision.exists()
        or revision.read_text().strip() != CONFIG["MODEL_REVISION"]
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
            "amanuensis_backend.download_model",
        )


def prepare(development):
    check_platform()
    run("uv", "sync", "--project", str(BACKEND), "--locked")
    fingerprint = hashlib.sha256(
        (BACKEND / "clients/package-lock.json").read_bytes()
    ).hexdigest()
    marker = BACKEND / "clients/node_modules/.amanuensis-lock"
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
    if development:
        ensure_model()
        return
    STAGING.mkdir(parents=True, exist_ok=True)
    base, granite = dependency_sets()
    dependency_hash = hashlib.sha256(render(base).encode()).hexdigest()
    dependency_marker = STAGING / ".dependencies"
    if (
        not dependency_marker.exists()
        or dependency_marker.read_text() != dependency_hash
    ):
        install(base, "backend", STAGING / "site-packages")
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
    remove(STAGING / "models")
    copy_tree(BACKEND / "src", STAGING / "src")
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
        base_url = f"https://nodejs.org/dist/{NODE_VERSION}/"
        archive = REPO / "build" / archive_name
        urllib.request.urlretrieve(base_url + archive_name, archive)
        checksums = urllib.request.urlopen(base_url + "SHASUMS256.txt").read().decode()
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
    for unused in ("include", "share", "CHANGELOG.md", "README.md"):
        remove(STAGING / "node" / unused)
    embed_granite_manifest(granite_pack_id(granite))
    manifest = {
        "python": python_version(),
        "node": NODE_VERSION,
        "providers": json.loads((BACKEND / "clients/package.json").read_text())[
            "dependencies"
        ],
    }
    (STAGING / "runtime.json").write_text(json.dumps(manifest, indent=2) + "\n")


def embed_granite_manifest(pack_id):
    target = STAGING / "granite-pack.json"
    published = (
        json.loads(GRANITE_MANIFEST.read_text()) if GRANITE_MANIFEST.exists() else {}
    )
    if published.get("id") == pack_id:
        shutil.copyfile(GRANITE_MANIFEST, target)
        return
    remove(target)
    print(
        f"warning: Granite pack {pack_id} is not published; this build cannot "
        "download Docling Granite. Run `just granite-pack`.",
        file=sys.stderr,
    )


def prepare_granite():
    check_platform()
    run("uv", "sync", "--project", str(BACKEND), "--locked")
    ensure_model()
    _, granite = dependency_sets()
    pack_id = granite_pack_id(granite)
    pack = GRANITE_STAGING / pack_id
    manifest = pack / "granite.json"
    if not manifest.exists():
        if GRANITE_STAGING.exists():
            shutil.rmtree(GRANITE_STAGING)
        install(granite, "granite", pack / "site-packages")
        copy_tree(CONFIG["MODEL_PATH"], pack / "models" / CONFIG["MODEL_PATH"].name)
        manifest.write_text(
            json.dumps(
                {
                    "id": pack_id,
                    "python": python_version(),
                    "model": CONFIG["MODEL_ID"],
                    "revision": CONFIG["MODEL_REVISION"],
                },
                indent=2,
            )
            + "\n"
        )
    print(pack)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--development", action="store_true")
    mode.add_argument(
        "--granite",
        action="store_true",
        help="Stage the downloadable Granite pack and print its path",
    )
    mode.add_argument(
        "--granite-id",
        action="store_true",
        help="Print the Granite pack id for the locked dependencies",
    )
    arguments = parser.parse_args()
    if arguments.granite_id:
        print(granite_pack_id(dependency_sets()[1]))
    elif arguments.granite:
        prepare_granite()
    else:
        prepare(arguments.development)
