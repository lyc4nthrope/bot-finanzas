"""Builds docs/bot-finanzas.pdf from the Markdown documentation.

The Markdown files stay the single source of truth; this script only renders them.
Runs inside the docs/build image with the repository mounted at /repo.
"""
import datetime
import pathlib
import re

from markdown_it import MarkdownIt
from playwright.sync_api import sync_playwright

REPO = pathlib.Path("/repo")
SECTIONS = [
    "README.md",
    "docs/contract.md",
    "docs/workflow.md",
    "docs/adr/0001-stack.md",
    "docs/adr/0002-render-instead-of-hugging-face.md",
]
OUTPUT = REPO / "docs" / "bot-finanzas.pdf"

CSS = """
@page { size: A4; margin: 18mm 16mm 20mm 16mm; }
body { font-family: "Liberation Sans", "DejaVu Sans", sans-serif; font-size: 10.5pt;
       line-height: 1.5; color: #1f2328; }
h1 { font-size: 20pt; border-bottom: 2px solid #d0d7de; padding-bottom: 4px; margin-top: 0; }
h2 { font-size: 14pt; margin-top: 22px; border-bottom: 1px solid #eaeef2; padding-bottom: 2px; }
h3 { font-size: 12pt; }
code { font-family: "DejaVu Sans Mono", monospace; font-size: 9pt; background: #f2f4f7;
       padding: 1px 4px; border-radius: 3px; }
pre { background: #f6f8fa; padding: 10px; border-radius: 6px; overflow: hidden;
      white-space: pre-wrap; word-break: break-word; font-size: 8.5pt; }
pre code { background: none; padding: 0; }
pre { break-inside: avoid; }
table { border-collapse: collapse; width: 100%; margin: 10px 0; font-size: 9.5pt; }
th, td { border: 1px solid #d0d7de; padding: 5px 7px; text-align: left; vertical-align: top; }
th { background: #f6f8fa; }
img { max-width: 100%; border: 1px solid #d0d7de; border-radius: 4px; margin: 6px 0 14px; }
.keep { break-inside: avoid; }
.keep img { max-height: 98mm; width: auto; display: block; margin: 6px auto 14px; }
h1, h2, h3 { break-after: avoid; }
.section { break-before: page; }
.cover { height: 240mm; display: flex; flex-direction: column; justify-content: center; }
.cover h1 { font-size: 34pt; border: none; }
.cover p { font-size: 13pt; color: #57606a; margin: 4px 0; }
"""


# CommonMark + tables: renders lists and code blocks the way GitHub does.
RENDERER = MarkdownIt("commonmark").enable("table")


def keep_figures_with_headings(html):
    """Wraps each h2 block that contains an image so the heading never ends a page alone."""
    blocks = re.split(r"(?=<h2>)", html)
    return "".join(f'<div class="keep">{b}</div>' if "<img" in b and b.startswith("<h2>") else b
                   for b in blocks)


def render_section(relative_path):
    path = REPO / relative_path
    html = RENDERER.render(path.read_text(encoding="utf-8"))
    # Images are relative to their Markdown file; make them absolute for the browser.
    html = re.sub(
        r'src="(?!https?:|file:)([^"]+)"',
        lambda match: f'src="file://{(path.parent / match.group(1)).resolve()}"',
        html,
    )
    return keep_figures_with_headings(html)


def build_html():
    today = datetime.date.today().isoformat()
    cover = f"""
    <div class="cover">
      <h1>bot-finanzas</h1>
      <p>Bot de finanzas personales: slash commands de Discord, n8n y PostgreSQL</p>
      <p>Repositorio: https://github.com/lyc4nthrope/bot-finanzas</p>
      <p>Generado el {today}</p>
    </div>"""
    body = "".join(f'<div class="section">{render_section(s)}</div>' for s in SECTIONS)
    return f"<!doctype html><html lang='es'><head><meta charset='utf-8'><style>{CSS}</style></head><body>{cover}{body}</body></html>"


def main():
    html_path = REPO / "docs" / "build" / ".rendered.html"
    html_path.write_text(build_html(), encoding="utf-8")
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            page = browser.new_page()
            page.goto(f"file://{html_path}")
            page.wait_for_load_state("networkidle")
            page.pdf(
                path=str(OUTPUT),
                format="A4",
                print_background=True,
                display_header_footer=True,
                header_template="<span></span>",
                footer_template=(
                    '<div style="font-size:8px;width:100%;text-align:center;color:#57606a">'
                    'bot-finanzas · <span class="pageNumber"></span> / <span class="totalPages"></span></div>'
                ),
                margin={"top": "18mm", "bottom": "20mm", "left": "16mm", "right": "16mm"},
            )
            browser.close()
    finally:
        html_path.unlink(missing_ok=True)
    print(f"Wrote {OUTPUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
