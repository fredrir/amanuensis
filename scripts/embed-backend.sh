#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "${SRCROOT}"
if [[ "${CONFIGURATION}" == "Debug" ]]; then
    uv run --project backend --locked python scripts/prepare-backend.py --development
    exit 0
fi

uv run --project backend --locked python scripts/prepare-backend.py
destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Backend"
rm -rf "${destination}"
ditto build/backend "${destination}"
backend/.venv/bin/python3 scripts/sign-backend.py "${destination}" "${EXPANDED_CODE_SIGN_IDENTITY:--}"
