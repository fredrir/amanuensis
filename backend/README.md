# Backend

| Component | Owner |
|---|---|
| Capture, settings, clipboard | Swift |
| Inference, prompts, model discovery, parsing, output | Python + Docling |
| Local inference | Granite Docling 258M, MLX, Apple Silicon; downloadable pack |
| ChatGPT subscription | Bundled Codex app-server |
| Google subscription | Bundled Gemini CLI, ACP |
| API keys | Anthropic, Gemini, OpenAI-compatible endpoints |
| App transport | Private stdin/stdout JSON; no listening backend port |

| Command | Action |
|---|---|
| `just backend-setup` | Install Python dependencies (incl. `granite` group), clients, pinned Granite model |
| `just dev` | Start the app and managed backend |
| `just test` | Backend and Swift tests |
| `just build --no-install --no-package --adhoc` | Build a self-contained app |
| `just granite-pack` | Build, sign, notarize and publish the Granite pack; updates `granite-pack.json` |
| `./scripts/test-bundled-backend.sh` | Verify slim bundle, pack install, offline inference and client startup |

| Artifact | Contents |
|---|---|
| App bundle | Python, base dependencies, Node, provider clients, licenses |
| Granite pack | `granite` dependency group, model weights; GitHub release `granite-<id>` |
| `granite-pack.json` | Published pack id, URL, SHA-256, sizes; embedded only when its id matches the lock |

| Pack path | Value |
|---|---|
| Installed | `~/Library/Containers/app.fredrir.amanuensis/Data/Library/Application Support/Amanuensis/granite/<id>` |
| Backend env | `AMANUENSIS_GRANITE_ROOT` (fallback: backend root) |

The pack id hashes the pack requirements, model revision and Python version. `just deploy` publishes a new pack when the id changes.

Granite uses [Apache 2.0](https://huggingface.co/ibm-granite/granite-docling-258M-mlx). The pinned revision is in `config.py`; its license ships beside the weights in the pack. Dependency license files ship with their packages.

Account sessions are private to Amanuensis. Sign in from Settings; subscription availability and model access follow the provider account. API keys remain in the existing provider settings. Captures use the selected provider for Text, Markdown, and LaTeX.
