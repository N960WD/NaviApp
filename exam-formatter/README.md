# Exam Formatter

Upload an exam PDF and download it as a clean, modern Word document (.docx).

- **Fill-in-the-blank**: every `Blank 1`, `[Blank 2]`, `(Blank 3)` … marker becomes a numbered tag
  followed by an underlined writing space. Blanks listed on their own line (`Blank 1:`) become
  full-width labelled answer lines, and duplicates of inline blanks are dropped. Plain `_____` runs
  become unlabelled writing spaces.
- **Layout**: title and subtitle, a Name / Date / Score row (with the point total when every
  question has points), a shaded instructions box, section headings (`Part I`, `Section B`, bold
  ALL-CAPS lines), numbered questions with point values, lettered answer choices, ruled writing lines
  under open-ended questions, and a "Page X of Y" footer. Each question is kept on one page.
- **Clean-up**: page numbers and running headers/footers from the PDF are removed, and wrapped lines
  are rejoined.

Works with text-based PDFs, including Canvas-style exports (`Question 1` / `1 pts` headers, ○ answer
bubbles). Scanned PDFs need OCR first.

## Run the web app

```sh
cd exam-formatter
pip install -r requirements.txt
python app.py               # http://localhost:5000  (set PORT to change)
```

Choose or drag in a PDF. It's converted right away and the .docx downloads automatically.

## Command line

```sh
python -m exam_formatter exam.pdf               # writes "exam (formatted).docx"
python -m exam_formatter exam.pdf -o out.docx
```

## Tests

```sh
pip install pytest reportlab
python -m pytest tests
```

The tests generate two sample PDFs (`tests/make_sample_pdf.py`, `tests/make_canvas_pdf.py`).

## Code

| File | |
|---|---|
| `exam_formatter/parser.py` | PDF lines → `Exam` model (title, instructions, sections, questions, choices, points, blanks) |
| `exam_formatter/docx_writer.py` | `Exam` → styled .docx |
| `app.py`, `templates/index.html` | Flask upload/download page |
