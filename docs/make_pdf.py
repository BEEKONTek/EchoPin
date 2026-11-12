"""Turns a Markdown document in docs/ into a print-ready PDF.

    pip install markdown && python docs/make_pdf.py docs/IMPLEMENTATION.md

Needs chromium on PATH. Mermaid blocks are rendered as their source in a
box (GitHub draws them as diagrams online).
"""

import os
import re
import subprocess
import sys
import tempfile

import markdown

CSS = """
@page { size: A4; margin: 16mm 15mm; }
body { font-family: Arial, 'Liberation Sans', sans-serif; color: #1a1d26; font-size: 10.5pt; line-height: 1.5; }
h1 { font-size: 22pt; color: #2563EB; margin: 0 0 6pt; }
h2 { font-size: 15pt; margin: 20pt 0 6pt; padding-top: 6pt; border-top: 2px solid #e3e7f0; break-after: avoid; }
h3 { font-size: 12pt; margin: 12pt 0 4pt; break-after: avoid; }
p, li { margin: 4pt 0; }
code { font-family: 'DejaVu Sans Mono', monospace; font-size: 8.8pt; background: #eef1f8; padding: 1px 3px; border-radius: 3px; }
pre { background: #0e1016; color: #f3f5f9; padding: 8pt; border-radius: 6px; font-size: 8.3pt; overflow-x: auto; white-space: pre-wrap; }
pre code { background: none; color: inherit; }
table { border-collapse: collapse; width: 100%; margin: 6pt 0 10pt; font-size: 9pt; }
th, td { border: 1px solid #d9deea; padding: 4pt 6pt; text-align: left; vertical-align: top; }
th { background: #eef1f8; }
tr { break-inside: avoid; }
img { max-width: 100%; }
a { color: #2563EB; text-decoration: none; }
blockquote { border-left: 3px solid #2563EB; margin: 6pt 0; padding: 2pt 10pt; color: #3a3f4d; }
"""


def build(md_path, pdf_path=None):
    md_path = os.path.abspath(md_path)
    pdf_path = pdf_path or os.path.splitext(md_path)[0] + ".pdf"
    src = open(md_path, encoding="utf-8").read()
    # Mermaid is for GitHub; print the source in a box so nothing is lost.
    src = re.sub(r"```mermaid\n(.*?)```", r"```text\n\1```", src, flags=re.S)
    body = markdown.markdown(src, extensions=["tables", "fenced_code", "toc"])
    body = body.replace("\\|", "|")
    base = "file://" + os.path.dirname(md_path) + "/"
    page = (f'<!doctype html><meta charset="utf-8"><base href="{base}">'
            f"<style>{CSS}</style><body>{body}</body>")
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, encoding="utf-8") as f:
        f.write(page)
    subprocess.run(["chromium", "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                    f"--print-to-pdf={pdf_path}", f"file://{f.name}"], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.unlink(f.name)
    print(pdf_path)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for path in sys.argv[1:]:
        build(path)
