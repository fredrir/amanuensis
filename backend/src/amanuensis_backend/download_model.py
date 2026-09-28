import shutil

from huggingface_hub import snapshot_download

from .config import MODEL_ID, MODEL_PATH, MODEL_REVISION, ROOT


def main():
    snapshot_download(
        MODEL_ID,
        revision=MODEL_REVISION,
        local_dir=MODEL_PATH,
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
    shutil.copyfile(ROOT / "licenses/Apache-2.0.txt", MODEL_PATH / "LICENSE")
    (MODEL_PATH / "REVISION").write_text(MODEL_REVISION + "\n")


if __name__ == "__main__":
    main()
