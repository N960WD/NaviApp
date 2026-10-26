"""Web front end: upload an exam PDF, get a formatted Word document back.

Run:  python app.py      then open http://localhost:5000
"""

import io
import os
import re
import tempfile
from pathlib import Path

from flask import Flask, jsonify, render_template, request, send_file

from exam_formatter import convert

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 40 * 1024 * 1024  # 40 MB

DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"


@app.get("/")
def index():
    return render_template("index.html")


@app.post("/convert")
def convert_pdf():
    upload = request.files.get("file")
    if upload is None or not upload.filename:
        return jsonify(error="Choose a PDF file to upload."), 400
    data = upload.read()
    if not data.startswith(b"%PDF"):
        return jsonify(error="That file isn't a PDF."), 400

    stem = re.sub(r"[^\w\- ]+", "", Path(upload.filename).stem).strip() or "exam"
    with tempfile.TemporaryDirectory() as tmp:
        pdf_path = os.path.join(tmp, "in.pdf")
        docx_path = os.path.join(tmp, "out.docx")
        with open(pdf_path, "wb") as f:
            f.write(data)
        try:
            exam = convert(pdf_path, docx_path)
        except Exception as exc:  # malformed or encrypted PDFs
            app.logger.exception("conversion failed")
            return jsonify(error=f"Couldn't read this PDF ({exc.__class__.__name__})."), 422
        if not exam.blocks and not exam.instructions:
            return jsonify(error="No text found. Scanned PDFs need OCR first."), 422
        with open(docx_path, "rb") as f:
            out = io.BytesIO(f.read())

    resp = send_file(out, mimetype=DOCX_MIME, as_attachment=True, download_name=f"{stem} (formatted).docx")
    resp.headers["X-Question-Count"] = str(len(exam.questions))
    resp.headers["Access-Control-Expose-Headers"] = "X-Question-Count, Content-Disposition"
    return resp


@app.errorhandler(413)
def too_large(_):
    return jsonify(error="File is larger than 40 MB."), 413


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)))
