"""Command line: python -m exam_formatter exam.pdf [-o exam.docx]"""

import argparse
from pathlib import Path

from . import convert


def main() -> None:
    ap = argparse.ArgumentParser(description="Format an exam PDF as a Word document.")
    ap.add_argument("pdf", type=Path)
    ap.add_argument("-o", "--output", type=Path, help="output .docx (default: next to the PDF)")
    args = ap.parse_args()
    out = args.output or args.pdf.with_name(args.pdf.stem + " (formatted).docx")
    exam = convert(str(args.pdf), str(out))
    print(f"{len(exam.questions)} questions -> {out}")


if __name__ == "__main__":
    main()
