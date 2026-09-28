import shutil

from huggingface_hub import snapshot_download

from .config import MODEL_ID, MODEL_REVISION, MODEL_ROOT, ROOT


def main():
    destination = MODEL_ROOT / MODEL_ID.replace("/", "--")
    snapshot_download(
        MODEL_ID,
        revision=MODEL_REVISION,
        local_dir=destination,
        allow_patterns=[
            "*.json",
            "*.safetensors",
            "*.txt",
            "*.jinja",
            "README.md",
            "LICENSE*",
            "NOTICE*",
        ],
    )
    shutil.copyfile(ROOT / "licenses/Apache-2.0.txt", destination / "LICENSE")
    (destination / "REVISION").write_text(MODEL_REVISION + "\n")


if __name__ == "__main__":
    main()
