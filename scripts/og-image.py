#!/usr/bin/env python3
"""Render docs/og-image.png, the link-preview card for social unfurls.

    ./scripts/og-image.py

Re-run it whenever the pad illustration or the pitch changes. It lays the card
out as HTML — text wrapping and font metrics are a browser's job, not
something worth reimplementing — and screenshots it with headless Chrome at
exactly 1200x630, the size Twitter/X, Slack, Discord and iMessage expect for a
large summary card.

SVG is deliberately not an option here: no unfurler renders it.
"""

import pathlib
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
OUT = REPO / "docs/og-image.png"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

TITLE = "Micro Manager"
PITCH = "Your coding agents, lit up on your keyboard."
SUB = ("Each Herdr agent gets its own key on a Work Louder Creator Micro 2 — "
       "red when it needs you, amber while it works. Press the key, jump to "
       "the agent.")
URL = "schacon.github.io/micro-manager"

CARD = """<!doctype html>
<html><head><meta charset="utf-8"><style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { width: 1200px; height: 630px; overflow: hidden; }
  body {
    display: flex; align-items: center; gap: 56px; padding: 0 76px;
    background: #0C0E13;
    font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
    color: #F2F5F9; position: relative;
  }
  /* the same bloom the pad sits in on the site, so the card feels of a piece */
  .bloom { position: absolute; right: -60px; top: 50%; transform: translateY(-50%);
           width: 760px; height: 760px; border-radius: 50%;
           background: radial-gradient(circle, rgba(62,107,255,.30), rgba(62,107,255,0) 62%); }
  .copy { position: relative; flex: 1 1 auto; min-width: 0; }
  h1 { font-size: 82px; line-height: 1.0; letter-spacing: -.035em; font-weight: 700; }
  .pitch { font-size: 33px; line-height: 1.28; margin-top: 22px; color: #E4E9F0;
           letter-spacing: -.012em; }
  .sub { font-size: 22px; line-height: 1.45; margin-top: 20px; color: #98A2B3;
         max-width: 30em; }
  .foot { display: flex; align-items: center; gap: 12px; margin-top: 40px;
          font-size: 20px; color: #7C8698; }
  .dots { display: flex; gap: 7px; }
  .dots i { width: 11px; height: 11px; border-radius: 50%; display: block; }
  .pad { position: relative; flex: 0 0 348px; width: 348px; }
  .pad svg { display: block; width: 100%; height: auto; }
</style></head><body>
  <div class="bloom"></div>
  <div class="copy">
    <h1>__TITLE__</h1>
    <p class="pitch">__PITCH__</p>
    <p class="sub">__SUB__</p>
    <div class="foot">
      <span class="dots"><i style="background:#FF2D2D"></i><i style="background:#FFA000"></i>
        <i style="background:#00B0FF"></i><i style="background:#00C853"></i></span>
      <span>__URL__</span>
    </div>
  </div>
  <div class="pad">__SVG__</div>
</body></html>"""


def main():
    if not pathlib.Path(CHROME).exists():
        sys.exit(f"Google Chrome not found at {CHROME} — it does the rasterising.")

    svg = subprocess.run([sys.executable, str(REPO / "scripts/pad-illustration.py")],
                         capture_output=True, text=True, check=True).stdout.strip()

    html = (CARD.replace("__TITLE__", TITLE).replace("__PITCH__", PITCH)
                .replace("__SUB__", SUB).replace("__URL__", URL)
                .replace("__SVG__", svg))

    with tempfile.TemporaryDirectory() as tmp:
        page = pathlib.Path(tmp) / "card.html"
        page.write_text(html)
        subprocess.run([
            CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
            "--force-device-scale-factor=1", "--window-size=1200,630",
            f"--screenshot={OUT}", page.as_uri(),
        ], check=True, capture_output=True)

    print(f"wrote {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
