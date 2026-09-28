set shell := ["bash", "-euo", "pipefail", "-c"]

_default:
	@just --list

project := "ScreenScribe.xcodeproj"
scheme := "ScreenScribe"
dest := "platform=macOS"
derived_data := "build/xcode"
app_path := home_directory() / "Applications/ScreenScribe.app"

# Build once, launch, and inject Swift changes in-process (no relaunch).
dev:
	@./scripts/dev.sh

# Full rebuild + relaunch
restart:
	@./scripts/relaunch.sh

# Open the project in Xcode.
xcode:
	@open {{project}}

# Type-check with SPM (fast and quiet).
typecheck:
	@swift build

# Build, sign, package, and install ScreenScribe.app [ --no-install --no-package --adhoc ]
build *args:
	@./scripts/build.sh {{args}}

# Build, sign, notarize, package, and install a Developer ID release [ --notary-profile --no-install ]
deploy *args:
	@./scripts/deploy.sh {{args}}

# Backend and Swift tests.
test:
	@uv run --project backend pytest backend/tests
	@./scripts/run-standalone-tests.sh

verify-signing path=app_path:
	@./scripts/verify-release-signing.sh "{{path}}"

clean:
	@rm -rf build .build

appicon:
	@xcrun swift scripts/render-app-icon.swift

# Raw xcodebuild output, used by the VSCode problem matcher.
[private]
build-raw config="Debug":
	@xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{config}} -destination '{{dest}}' -derivedDataPath {{derived_data}} build

# Install the local backend, provider clients and Granite model.
backend-setup:
	@uv run --project backend --locked python scripts/prepare-backend.py --development
