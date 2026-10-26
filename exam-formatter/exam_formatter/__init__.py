"""Convert exam PDFs into clean, modern Word documents."""

from .docx_writer import build_docx
from .parser import Exam, parse_pdf


def convert(pdf_path: str, docx_path: str) -> Exam:
    """Parse ``pdf_path`` and write the formatted exam to ``docx_path``."""
    exam = parse_pdf(pdf_path)
    build_docx(exam, docx_path)
    return exam


__all__ = ["Exam", "build_docx", "convert", "parse_pdf"]
