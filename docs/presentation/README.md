# EchoPin v0.4 update: presentation pack

| File | What it is |
| --- | --- |
| `EchoPin_v0.4_Update.pptx` | The deck: 15 slides, 16:9, animated. The speech is in each slide's speaker notes (▶ = advance) |
| `SPEECH.md` / `SPEECH.pdf` | The talk, about 13½ minutes, with **[CLICK]** cues and target times per slide |
| `CODE_REFERENCE.md` / `CODE_REFERENCE.pdf` | Answers for code questions: every function by file and line, rapid-fire answers, numbers to remember |
| `assets/` | Screenshots from the end-to-end test run |
| `build_deck.py`, `deck_lib.py`, `make_pdfs.py` | Regenerate everything (see below) |

## Presenting

- **Best in PowerPoint 2019 / 365.** Slides 1→2 and 14→15 use *Morph* (the
  pinwheel logo glides between slides). Other apps play those as a fade.
  LibreOffice Impress plays the other animations; Google Slides drops most
  of them.
- **Every content slide builds on click.** Slides 1 and 15, the column
  headings on slide 5 and the timeline line on slide 7 animate on their own. There are 41 clicks in total, and
  the speech marks each one.
- **Fonts:** Arial throughout, so it looks the same on Windows, macOS and
  Linux (Liberation Sans).
- **Running long?** Skip slide 12 (*See it*): about 45 seconds saved.

## Rebuilding

The speech text lives in `build_deck.py`, so the deck's notes and
`SPEECH.md` can't drift apart. The build stops if the number of
**[CLICK]** cues on a slide doesn't match its click animations.

    python -m venv .venv && .venv/bin/pip install python-pptx markdown
    .venv/bin/python build_deck.py            # deck + SPEECH.md
    .venv/bin/python make_pdfs.py             # PDFs (needs chromium)

`CODE_REFERENCE.md` is written by hand. Its line numbers are as of
8 November 2026; update them if the code moves.
