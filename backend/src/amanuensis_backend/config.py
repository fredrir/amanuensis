import os
from pathlib import Path

MODEL_ID = "ibm-granite/granite-docling-258M-mlx"
MODEL_REVISION = "e9939db25d2f296c8678d0491c4609a8c596c50a"
ROOT = Path(
    os.environ.get("AMANUENSIS_BACKEND_ROOT", Path(__file__).resolve().parents[2])
)
GRANITE_ROOT = Path(os.environ.get("AMANUENSIS_GRANITE_ROOT", ROOT))
GRANITE_PACKAGES = GRANITE_ROOT / "site-packages"
MODEL_ROOT = GRANITE_ROOT / "models"
MODEL_PATH = MODEL_ROOT / MODEL_ID.replace("/", "--")
STATE_ROOT = Path(
    os.environ.get(
        "AMANUENSIS_STATE_ROOT",
        Path.home() / "Library/Application Support/Amanuensis/backend",
    )
)


class BackendError(Exception):
    def __init__(self, message: str, code: str = "extraction_failed"):
        super().__init__(message)
        self.code = code


def granite_ready():
    return (MODEL_PATH / "model.safetensors").is_file()


def require_granite():
    if not granite_ready():
        raise BackendError(
            "Docling Granite is not installed. Download it in Settings.",
            "granite_missing",
        )
