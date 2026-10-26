"""Generate tests/canvas_exam.pdf: a Canvas-style export ("Question N" / "1 pts" headers, bubble choices)."""

from pathlib import Path

from reportlab.lib.pagesizes import letter
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas

# Helvetica can't encode the answer bubbles, so embed a Unicode font.
pdfmetrics.registerFont(TTFont("DejaVu", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"))

OUT = Path(__file__).with_name("canvas_exam.pdf")
c = canvas.Canvas(str(OUT), pagesize=letter)
y = 740


def line(text, size=11, font="Helvetica", gap=16):
    global y
    if y < 80:
        c.drawString(72, 40, "Chemistry Quiz 3 - Print Version")
        c.showPage()
        y = 740
    c.setFont(font, size)
    c.drawString(72, y, text)
    y -= gap


line("Chemistry Quiz 3", 18, "Helvetica-Bold", 28)
for n in range(1, 9):
    line(f"Question {n}", 12, "Helvetica-Bold", 16)
    line("1 pts", 9, "Helvetica", 18)
    if n % 2:
        line(f"Water is made of [Blank 1] hydrogen atoms and [Blank 2] oxygen atom (item {n}).")
        line("Blank 1:")
        line("Blank 2:", gap=26)
    else:
        line(f"Which gas is most abundant in Earth's atmosphere? (item {n})")
        for opt in ("Oxygen", "Nitrogen", "Argon", "Carbon dioxide"):
            line(f"○ {opt}", font="DejaVu")
        y -= 10
c.drawString(72, 40, "Chemistry Quiz 3 - Print Version")
c.save()
print(OUT)
