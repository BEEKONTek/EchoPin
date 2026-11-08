"""Turns SPEECH.md and CODE_REFERENCE.md into print-ready PDFs.

    pip install markdown && python make_pdfs.py      # needs chromium on PATH
"""

import os
import subprocess
import tempfile

import markdown

HERE = os.path.dirname(os.path.abspath(__file__))

CSS = """
@page { size: A4; margin: 16mm 15mm; }
body { font-family: Arial, 'Liberation Sans', sans-serif; color: #1a1d26; font-size: 10.5pt; line-height: 1.5; }
h1 { font-size: 22pt; color: #2563EB; margin: 0 0 6pt; }
h2 { font-size: 14pt; margin: 18pt 0 6pt; padding-top: 6pt; border-top: 2px solid #e3e7f0; break-after: avoid; }
h3 { font-size: 12pt; margin: 12pt 0 4pt; }
p, li { margin: 4pt 0; }
code { font-family: 'DejaVu Sans Mono', monospace; font-size: 8.8pt; background: #eef1f8; padding: 1px 3px; border-radius: 3px; }
pre { background: #0e1016; color: #f3f5f9; padding: 8pt; border-radius: 6px; font-size: 8.5pt; overflow-x: auto; }
pre code { background: none; color: inherit; }
table { border-collapse: collapse; width: 100%; margin: 6pt 0 10pt; font-size: 9pt; }
th, td { border: 1px solid #d9deea; padding: 4pt 6pt; text-align: left; vertical-align: top; }
th { background: #eef1f8; }
tr { break-inside: avoid; }
strong { color: #0e1016; }
a { color: #2563EB; text-decoration: none; }
hr { border: none; border-top: 1px solid #d9deea; margin: 12pt 0; }
.speech p { font-size: 13pt; line-height: 1.6; }
.speech strong { color: #DC2626; }
"""


def build(md_name, pdf_name, cls=""):
    src = open(os.path.join(HERE, md_name)).read()
    body = markdown.markdown(src, extensions=["tables", "fenced_code", "toc"])
    # `\|` keeps pipes inside code from splitting table cells on GitHub;
    # python-markdown leaves the backslash in, so drop it for print.
    body = body.replace("\\|", "|")
    page = (f'<!doctype html><meta charset="utf-8"><style>{CSS}</style>'
            f'<body class="{cls}">{body}</body>')
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(page)
    out = os.path.join(HERE, pdf_name)
    subprocess.run(["chromium", "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                    f"--print-to-pdf={out}", f"file://{f.name}"], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.unlink(f.name)
    print(out)


if __name__ == "__main__":
    build("SPEECH.md", "SPEECH.pdf", "speech")
    build("CODE_REFERENCE.md", "CODE_REFERENCE.pdf")
