import re

from docling_core.transforms.serializer.common import create_ser_result
from docling_core.transforms.serializer.latex import LaTeXDocSerializer
from docling_core.transforms.serializer.markdown import (
    MarkdownDocSerializer,
    MarkdownInlineSerializer,
    MarkdownTextSerializer,
)
from docling_core.transforms.serializer.plain_text import PlainTextDocSerializer
from docling_core.types.doc import CodeItem


class InlineSerializer(MarkdownInlineSerializer):
    def serialize(self, *, item, doc_serializer, doc, **kwargs):
        parts = doc_serializer.get_parts(item=item, is_inline_scope=True, **kwargs)
        text = ""
        for part in parts:
            if not part.text:
                continue
            separator = (
                " "
                if text and part.text[0] not in ".,;:!?)]}" and text[-1] not in "([{"
                else ""
            )
            text += separator + part.text
        return create_ser_result(text=text, span_source=parts)


class CodeSerializer(MarkdownTextSerializer):
    def serialize(self, *, item, doc_serializer, doc, **kwargs):
        if isinstance(item, CodeItem) and not kwargs.get("is_inline_scope"):
            language = item.code_language.value.lower()
            if language in ("unknown", "text"):
                language = ""
            fence = "`" * max(
                3,
                max(
                    (len(m.group()) + 1 for m in re.finditer(r"`+", item.text)),
                    default=3,
                ),
            )
            return create_ser_result(
                text=f"{fence}{language}\n{item.text}\n{fence}", span_source=item
            )
        return super().serialize(
            item=item, doc_serializer=doc_serializer, doc=doc, **kwargs
        )


def escape_prose(text):
    parts = re.split(r"(\$\$[\s\S]*?\$\$|(?<!\\)\$(?:\\.|[^$])*?(?<!\\)\$)", text)
    escapes = {
        "\\": r"\textbackslash{}",
        "&": r"\&",
        "%": r"\%",
        "$": r"\$",
        "#": r"\#",
        "_": r"\_",
        "{": r"\{",
        "}": r"\}",
        "~": r"\textasciitilde{}",
        "^": r"\textasciicircum{}",
    }
    return "".join(
        part if i % 2 else "".join(escapes.get(c, c) for c in part)
        for i, part in enumerate(parts)
    )


class LaTeXFragmentSerializer(LaTeXDocSerializer):
    def serialize_doc(self, *, parts, **kwargs):
        return create_ser_result(
            text="\n\n".join(part.text for part in parts if part.text),
            span_source=parts,
        )

    def post_process(self, text, **kwargs):
        return super().post_process(
            escape_prose(text), **{**kwargs, "escape_latex": False}
        )


def serialize(document, output_format):
    inline = InlineSerializer()
    if output_format == "latex":
        serializer = LaTeXFragmentSerializer(doc=document, inline_serializer=inline)
    elif output_format == "text":
        serializer = PlainTextDocSerializer(doc=document, inline_serializer=inline)
    else:
        serializer = MarkdownDocSerializer(
            doc=document, inline_serializer=inline, text_serializer=CodeSerializer()
        )
    return serializer.serialize().text.strip()
