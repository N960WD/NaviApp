"""Turn the text of an exam PDF into a structured Exam model.

The parser works on visual lines (from pdfplumber) and recognises:
  * a title (the largest text before the first question)
  * instructions / preamble paragraphs
  * section headings ("Part II", "Section B: ...", short ALL-CAPS lines)
  * numbered questions ("1.", "1)", "Question 1")
  * answer choices ("A.", "b)", "(c)", bubble glyphs)
  * point values ("(5 points)", "2 pts")
  * fill-in-the-blank markers ("Blank 1", "[Blank 2]", "(Blank 3)")
"""

from __future__ import annotations

import re
import statistics
from collections import Counter
from dataclasses import dataclass, field

import pdfplumber

# ---------------------------------------------------------------- model


@dataclass
class Option:
    label: str
    text: str


@dataclass
class Question:
    number: int
    paragraphs: list[str] = field(default_factory=list)
    options: list[Option] = field(default_factory=list)
    points: str | None = None
    # Blank numbers listed on their own line (answer fields) rather than inline.
    answer_blanks: list[int] = field(default_factory=list)


@dataclass
class Section:
    title: str
    paragraphs: list[str] = field(default_factory=list)


@dataclass
class Exam:
    title: str = "Exam"
    subtitle: list[str] = field(default_factory=list)
    instructions: list[str] = field(default_factory=list)
    blocks: list[Question | Section] = field(default_factory=list)

    @property
    def questions(self) -> list[Question]:
        return [b for b in self.blocks if isinstance(b, Question)]


@dataclass
class Line:
    text: str
    page: int
    top: float
    bottom: float
    size: float
    bold: bool


# ---------------------------------------------------------------- patterns

# "Blank 1", "[Blank 1]", "(Blank 1)", "{Blank 1}", optionally padded with underscores.
BLANK_RE = re.compile(
    r"_*\s*[\[\(\{]?\s*\bBlank\s*#?\s*(\d+)\b\s*[\]\)\}]?\s*_*", re.IGNORECASE
)
# A line made up only of blank markers (an answer field list), e.g. "Blank 1: ______".
STANDALONE_BLANKS_RE = re.compile(
    r"^(?:\s*[\[\(\{]?\s*Blank\s*#?\s*\d+\s*[\]\)\}]?\s*[:.\-]?\s*_*\s*)+$", re.IGNORECASE
)
UNDERSCORES_RE = re.compile(r"_{3,}")

QUESTION_RE = re.compile(r"^\s*(?:Q(?:uestion)?\.?\s*)?(\d{1,3})\s*[.)]\s*(.*)$", re.IGNORECASE)
QUESTION_HEADER_RE = re.compile(r"^\s*Question\s+(\d{1,3})\b[:.]?\s*(.*)$", re.IGNORECASE)
OPTION_RE = re.compile(r"^\s*(?:\(([A-Ha-h])\)|([A-Ha-h])[.)])\s+(.*)$")
BUBBLE_RE = re.compile(r"^\s*[○◯◦●□☐❍⚪•]\s*(.*)$")
POINTS_INLINE_RE = re.compile(
    r"\s*[\(\[]\s*(\d+(?:\.\d+)?)\s*(points?|pts?\.?|marks?)\s*[\)\]]\s*", re.IGNORECASE
)
POINTS_LINE_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*(points?|pts?\.?|marks?)\s*$", re.IGNORECASE)
SECTION_RE = re.compile(
    r"^\s*(?:Part|Section|Unit)\s+(?:[IVXLC]+|\d+|[A-Z])\b.*$", re.IGNORECASE
)
PAGE_NUM_RE = re.compile(r"^\s*(?:page\s*)?\d+\s*(?:(?:of|/)\s*\d+)?\s*$", re.IGNORECASE)
HEADER_FIELD_RE = re.compile(
    r"^\s*(?:(?:student\s+)?name|date|score|grade|class|period|teacher|id)\s*[:_]", re.IGNORECASE
)


def blank_label(n: int) -> str:
    return f"Blank {n}"


# ---------------------------------------------------------------- extraction


def extract_lines(pdf_path: str) -> list[Line]:
    lines: list[Line] = []
    with pdfplumber.open(pdf_path) as pdf:
        n_pages = len(pdf.pages)
        raw: list[tuple[Line, float]] = []
        for pno, page in enumerate(pdf.pages):
            height = float(page.height) or 792.0
            for tl in page.extract_text_lines(return_chars=True, keep_blank_chars=False):
                text = re.sub(r"\s+", " ", tl["text"]).strip()
                if not text:
                    continue
                chars = [c for c in tl.get("chars", []) if c.get("text", "").strip()]
                sizes = [round(float(c.get("size", 0)), 1) for c in chars] or [0.0]
                bold = bool(chars) and sum(
                    1 for c in chars if re.search(r"bold|black|heavy|semibold", c.get("fontname", ""), re.I)
                ) > len(chars) / 2
                line = Line(text, pno, float(tl["top"]), float(tl["bottom"]), statistics.median(sizes), bold)
                raw.append((line, height))

    # Drop running headers/footers: page numbers in the margins, and text that
    # repeats in the margins of many pages.
    def in_margin(line: Line, height: float) -> bool:
        return line.top < height * 0.08 or line.bottom > height * 0.92

    def norm(t: str) -> str:
        return re.sub(r"\d+", "#", t.lower())

    repeated = Counter(norm(l.text) for l, h in raw if in_margin(l, h))
    threshold = max(2, n_pages // 2) if n_pages > 1 else 10**9
    for line, height in raw:
        if in_margin(line, height):
            if PAGE_NUM_RE.match(line.text) or repeated[norm(line.text)] >= threshold:
                continue
        lines.append(line)
    return lines


# ---------------------------------------------------------------- parsing


def _join(prev: str, nxt: str) -> str:
    if not prev:
        return nxt
    if re.search(r"[A-Za-z]-$", prev) and nxt[:1].islower():
        return prev[:-1] + nxt
    return f"{prev} {nxt}"


def _is_section(line: Line, body_size: float) -> bool:
    t = line.text
    if SECTION_RE.match(t) and len(t) < 90:
        return True
    letters = [c for c in t if c.isalpha()]
    return (
        len(t) <= 60
        and len(letters) >= 4
        and all(c.isupper() for c in letters)
        and not OPTION_RE.match(t)
        and t.strip(" .") not in ("TRUE", "FALSE", "TRUE/FALSE", "NONE OF THE ABOVE", "ALL OF THE ABOVE")
        and (line.bold or line.size >= body_size * 1.05)
    )


def _split_inline_options(text: str) -> list[Option] | None:
    """Split 'A. 3  B. 4  C. 5' into options when the labels are sequential."""
    parts = re.split(r"(?:(?<=\s)|^)\(?([A-H])[.)]\s+", text)
    if len(parts) < 5 or parts[0].strip():
        return None
    labels = parts[1::2]
    if [ord(l) - ord(labels[0]) for l in labels] != list(range(len(labels))):
        return None
    return [Option(l, t.strip()) for l, t in zip(labels, parts[2::2])]


def _take_points(text: str, q: Question) -> str:
    m = POINTS_INLINE_RE.search(text)
    if m and q.points is None:
        q.points = _fmt_points(m.group(1))
        text = (text[: m.start()] + " " + text[m.end():]).strip()
    return text


def _fmt_points(value: str) -> str:
    return f"{value} pt" if value in ("1", "1.0") else f"{value} pts"


def parse_lines(lines: list[Line]) -> Exam:
    exam = Exam()
    if not lines:
        return exam

    body_size = statistics.median(l.size for l in lines)
    preamble: list[Line] = []
    current: Question | Section | None = None
    last_q = 0
    # Where text continuation goes: "para", "option" or None (start a new paragraph).
    mode: str | None = None
    prev_line: Line | None = None
    bubble_count = 0

    def gap_break(line: Line) -> bool:
        if prev_line is None or prev_line.page != line.page:
            return False
        height = max(prev_line.bottom - prev_line.top, 1.0)
        return line.top - prev_line.bottom > height * 0.75

    for line in lines:
        text = line.text
        qh = QUESTION_HEADER_RE.match(text)
        qm = QUESTION_RE.match(text)
        num = None
        rest = ""
        if qh:
            num, rest = int(qh.group(1)), qh.group(2)
        elif qm and not STANDALONE_BLANKS_RE.match(text):
            n = int(qm.group(1))
            if last_q == 0 or n == last_q + 1 or n == 1:
                num, rest = n, qm.group(2)

        if num is not None:
            current = Question(num)
            exam.blocks.append(current)
            last_q = num
            bubble_count = 0
            mode = None
            rest = rest.strip()
            if rest:
                pm = POINTS_LINE_RE.match(rest)
                if pm:
                    current.points = _fmt_points(pm.group(1))
                else:
                    current.paragraphs.append(_take_points(rest, current))
                    mode = "para"
            prev_line = line
            continue

        if SECTION_RE.match(text) or (current is not None and _is_section(line, body_size)):
            current = Section(text.strip())
            exam.blocks.append(current)
            mode = None
            prev_line = line
            continue

        if current is None:
            preamble.append(line)
            prev_line = line
            continue

        if isinstance(current, Section):
            if mode == "para" and not gap_break(line) and current.paragraphs:
                current.paragraphs[-1] = _join(current.paragraphs[-1], text)
            else:
                current.paragraphs.append(text)
            mode = "para"
            prev_line = line
            continue

        q = current
        pm = POINTS_LINE_RE.match(text)
        if pm and q.points is None:
            q.points = _fmt_points(pm.group(1))
            prev_line = line
            continue

        if STANDALONE_BLANKS_RE.match(text):
            for n in re.findall(r"Blank\s*#?\s*(\d+)", text, re.IGNORECASE):
                q.answer_blanks.append(int(n))
            mode = None
            prev_line = line
            continue

        om = OPTION_RE.match(text)
        bm = BUBBLE_RE.match(text)
        inline = _split_inline_options(text)
        if inline and (q.paragraphs or q.options):
            q.options.extend(inline)
            mode = "option"
        elif om and (q.paragraphs or q.options):
            label = (om.group(1) or om.group(2)).upper()
            q.options.append(Option(label, om.group(3).strip()))
            mode = "option"
        elif bm and bm.group(1).strip():
            q.options.append(Option(chr(ord("A") + bubble_count), bm.group(1).strip()))
            bubble_count += 1
            mode = "option"
        elif mode == "option" and q.options and not gap_break(line):
            q.options[-1].text = _join(q.options[-1].text, text)
        elif mode == "para" and q.paragraphs and not gap_break(line):
            q.paragraphs[-1] = _join(q.paragraphs[-1], text)
            q.paragraphs[-1] = _take_points(q.paragraphs[-1], q)
        else:
            q.paragraphs.append(_take_points(text, q))
            mode = "para"
        prev_line = line

    _build_preamble(exam, preamble, body_size)

    # Blank fields listed separately are redundant when the stem already has them inline.
    for q in exam.questions:
        inline = {int(n) for p in q.paragraphs for n in BLANK_RE.findall(p)}
        q.answer_blanks = [n for n in dict.fromkeys(q.answer_blanks) if n not in inline]
    return exam


def _build_preamble(exam: Exam, preamble: list[Line], body_size: float) -> None:
    preamble = [l for l in preamble if not HEADER_FIELD_RE.match(l.text)]
    if not preamble:
        return
    max_size = max(l.size for l in preamble)
    if max_size >= body_size * 1.15:
        title_lines = [l for l in preamble if l.size >= max_size - 0.5]
        # Only the leading run of large lines is the title.
        first = preamble.index(title_lines[0])
        run = []
        for l in preamble[first:]:
            if l.size >= max_size - 0.5:
                run.append(l)
            else:
                break
        rest = preamble[:first] + preamble[first + len(run):]
    else:
        run, rest = preamble[:1], preamble[1:]
    exam.title = " ".join(l.text for l in run)

    # Up to three short lines right after the title (course, teacher, date) form the subtitle.
    while rest and len(exam.subtitle) < 3:
        t = rest[0].text
        if len(t) >= 70 or re.search(r"[.:]$", t) or re.match(r"^\s*(instructions|directions)\b", t, re.I):
            break
        exam.subtitle.append(t)
        rest = rest[1:]

    paras: list[str] = []
    prev: Line | None = None
    for l in rest:
        if re.match(r"^\s*(instructions|directions)\s*:?\s*$", l.text, re.I):
            prev = None
            continue
        text = re.sub(r"^\s*(instructions|directions)\s*:\s*", "", l.text, flags=re.I)
        broke = (
            prev is None
            or prev.page != l.page
            or l.top - prev.bottom > max(prev.bottom - prev.top, 1) * 0.75
            or BUBBLE_RE.match(l.text)
            or re.match(r"^\s*(\d+[.)]|[-–•])\s", l.text)
        )
        if paras and not broke:
            paras[-1] = _join(paras[-1], text)
        elif text:
            paras.append(text)
        prev = l
    exam.instructions = paras


def parse_pdf(pdf_path: str) -> Exam:
    return parse_lines(extract_lines(pdf_path))
