"""Generate tests/sample_exam.pdf: a plain, LMS-export-style exam used to test the formatter."""

from pathlib import Path

from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer

OUT = Path(__file__).with_name("sample_exam.pdf")

ss = getSampleStyleSheet()
body, h1 = ss["BodyText"], ss["Title"]
lines = [
    ("h1", "Biology 101 Midterm Exam"),
    ("p", "Fall Semester 2026"),
    ("p", "Name: ____________________"),
    ("p", "Instructions: Answer every question. For fill-in-the-blank questions, write the "
          "missing word in each blank. Calculators are not permitted. You have 50 minutes."),
    ("b", "PART I: MULTIPLE CHOICE"),
    ("p", "1. Which organelle is known as the powerhouse of the cell? (2 points)"),
    ("p", "A. Nucleus"), ("p", "B. Mitochondria"), ("p", "C. Ribosome"), ("p", "D. Golgi apparatus"),
    ("p", "2. Which of the following molecules carries genetic information in most living "
          "organisms, including bacteria, plants and animals? (2 points)"),
    ("p", "A. ATP B. DNA C. Glucose D. Lipids"),
    ("b", "PART II: FILL IN THE BLANK"),
    ("p", "3. The process by which plants convert light energy into chemical energy is called "
          "[Blank 1], and it takes place in the [Blank 2]. (4 points)"),
    ("p", "4. The basic unit of heredity is the Blank 1, which is made of Blank 2. (4 points)"),
    ("p", "5. Name the three domains of life. (3 points)"),
    ("p", "Blank 1"), ("p", "Blank 2"), ("p", "Blank 3"),
    ("b", "PART III: SHORT ANSWER"),
    ("p", "6. Explain the difference between mitosis and meiosis. (5 points)"),
]
story = []
for kind, text in lines:
    if kind == "h1":
        story.append(Paragraph(text, h1))
    elif kind == "b":
        story += [Spacer(1, 10), Paragraph(f"<b>{text}</b>", body)]
    else:
        story.append(Paragraph(text, body))

SimpleDocTemplate(str(OUT), pagesize=letter).build(
    story, onLaterPages=lambda c, d: c.drawString(300, 30, f"Page {d.page}"),
    onFirstPage=lambda c, d: c.drawString(300, 30, f"Page {d.page}"),
)
print(OUT)
