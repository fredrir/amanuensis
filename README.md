# Amanuensis

Screen capture to text, Markdown and LaTeX.


## Installation

### Quick Install

1. **Download** the latest `.dmg` from [Releases](https://github.com/fredrir/amanuensis/releases/latest)
2. **Open** the DMG and drag Amanuensis to Applications
3. **Right-click** the app and select "Open" (required for first launch)


## Providers

| Provider | Authentication |
|---|---|
| Docling Granite | One-time download in Settings; offline, Apple Silicon |
| ChatGPT / Codex | ChatGPT sign-in |
| Gemini Subscription | Google sign-in |
| Anthropic, Gemini, OpenAI-compatible | API key |

## Building from Source

Requires an Apple Silicon Mac, Xcode, `uv`, `npm`, `just`, and `xcbeautify`. Release builds bundle the backend; Granite is a separate download. See [backend commands](backend/README.md).


```bash
git clone https://github.com/fredrir/amanuensis.git
cd amanuensis
cp .env.example .env
xcrun notarytool store-credentials <APPLE_NOTARY_PROFILE> --apple-id <apple-id> --team-id <APPLE_TEAM_ID>
```

| Recipe | Output |
|---|---|
| `just build` | `dist/Amanuensis-<version>-dev.dmg`, `~/Applications/Amanuensis.app` |
| `just deploy` | `dist/Amanuensis-<version>.dmg` (notarized), `~/Applications/Amanuensis.app` |

| Env | Default |
|---|---|
| `APPLE_DEVELOPER_ID_APPLICATION` | first `Developer ID Application:` identity in Keychain |
| `APPLE_TEAM_ID` | — |
| `APPLE_NOTARY_PROFILE` | required by `just deploy` |

## Acknowledgments

Built on top of [Screen-Scribe](https://github.com/SamuelZ12/screen-scribe) by SamuelZ12, which again is built on top of [TextGrabber2](https://github.com/TextGrabber2-app/TextGrabber2) by cyanzhong
