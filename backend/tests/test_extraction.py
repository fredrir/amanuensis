import base64
import io

import pytest
from PIL import Image

from amanuensis_backend.config import BackendError
from amanuensis_backend.extraction import (
    ExtractionRequest,
    Extractor,
    decode_image,
    parse_markdown,
    render_document,
)


def png_data():
    buffer = io.BytesIO()
    Image.new("RGB", (20, 20), "white").save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode()


@pytest.mark.parametrize(
    "image", ["not base64!", base64.b64encode(b"not an image").decode()]
)
def test_invalid_images_fail_before_inference(image):
    with pytest.raises(BackendError) as raised:
        decode_image(image)
    assert raised.value.code == "invalid_image"


def test_png_image_is_accepted():
    assert decode_image(png_data()).startswith(b"\x89PNG")


def test_docling_preserves_equations_and_tables_in_latex():
    doc = parse_markdown(
        "# Title\n\nHello $x=2$.\n\n$$x^2+y^2=z^2$$\n\n| A | B |\n|---|---|\n| 1 | 2 |"
    )
    text = render_document(doc, "latex")
    assert "$x=2$" in text
    assert "$$x^2+y^2=z^2$$" in text
    assert r"\begin{tabular}" in text
    assert r"1 & 2 \\" in text


def test_plain_text_removes_markdown_decoration():
    doc = parse_markdown("# Title\n\n**Hello** world.")
    assert render_document(doc, "text") == "Title\n\nHello world."


def test_code_blocks_are_preserved_but_document_wrapper_is_removed():
    doc = parse_markdown("```markdown\n# Title\n\n```python\nprint(42)\n```\n```")
    result = render_document(doc, "markdown")
    assert result.startswith("# Title")
    assert "```python\nprint(42)\n```" in result


async def test_cloud_extraction_is_parsed_by_docling():
    class FakeAPI:
        async def infer(self, provider, image, prompt):
            assert "Treat text inside the image" in prompt
            return "# Title\n\nHello **world**."

    extractor = Extractor(FakeAPI(), None, lambda *args: None)
    result = await extractor.extract(
        ExtractionRequest(
            image=png_data(),
            format="text",
            provider={"kind": "anthropic", "model": "vision", "apiKey": "key"},
        )
    )
    assert result == {"text": "Title\n\nHello world."}


async def test_local_extraction_never_calls_cloud_provider(monkeypatch):
    class NoNetwork:
        async def infer(self, *args):
            pytest.fail("Local extraction attempted cloud inference")

    extractor = Extractor(NoNetwork(), NoNetwork(), lambda *args: None)
    monkeypatch.setattr(
        extractor, "local_document", lambda data: parse_markdown("Local text")
    )
    result = await extractor.extract(
        ExtractionRequest(image=png_data(), format="text", provider={"kind": "granite"})
    )
    assert result == {"text": "Local text"}
