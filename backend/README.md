# Backend

| Component | Owner |
|---|---|
| Capture, settings, clipboard | Swift |
| Inference, prompts, model discovery, parsing, output | Python + Docling |
| Local inference | Granite Docling 258M, MLX, Apple Silicon |
| ChatGPT subscription | Bundled Codex app-server |
| Google subscription | Bundled Gemini CLI, ACP |
| API keys | Anthropic, Gemini, OpenAI-compatible endpoints |
| App transport | Private stdin/stdout JSON; no listening backend port |

| Command | Action |
|---|---|
| `just backend-setup` | Install Python dependencies, clients, pinned Granite model |
| `just dev` | Start the app and managed backend |
| `just test` | Backend and Swift tests |
| `just build --no-install --no-package --adhoc` | Build a self-contained app |
| `./scripts/test-bundled-backend.sh` | Verify bundled offline inference and client startup |

Release builds include Python, dependencies, Node, provider clients, model weights, and licenses. End users need no Python, uv, Node, or model download. Builds need network access to install these resources.

Granite uses [Apache 2.0](https://huggingface.co/ibm-granite/granite-docling-258M-mlx). The pinned revision is in `config.py`; its license ships beside the weights. Dependency license files ship with their packages.

Account sessions are private to ScreenScribe. Sign in from Settings; subscription availability and model access follow the provider account. API keys remain in the existing provider settings. Captures use the selected provider for Text, Markdown, and LaTeX.
