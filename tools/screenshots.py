#!/usr/bin/env python3
"""Regenerate the theme gallery used by README.md (docs/themes/*.png).

Runs the app with `php -S` (tests/router.php) and captures the entry page and the
editor once per theme with Playwright/Chromium.
Needs: php, `python3 -m pip install playwright && playwright install chromium`.
Usage: tools/screenshots.py [output_dir]      (default: docs/themes)
"""

from __future__ import annotations

import base64
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
PORT = 8094
BASE = f"http://127.0.0.1:{PORT}"
SAMPLE = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3… user@laptop\nrsync -aHAX --info=progress2 server:/srv/data/ ./\n"


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "docs/themes"
    out.mkdir(parents=True, exist_ok=True)
    themes = sorted(p.stem for p in (ROOT / "app/public/static/themes").glob("*.css"))
    work = Path(tempfile.mkdtemp())
    for zone in ("public", "private"):
        (work / "data" / zone).mkdir(parents=True)
    (work / "secret").write_text(base64.b64encode(os.urandom(48)).decode())
    theme_file = work / "theme"
    env = dict(os.environ, CP_DATA_DIR=str(work / "data"), CP_SECRET_FILE=str(work / "secret"),
               CP_THEME_FILE=str(theme_file))
    server = subprocess.Popen(
        ["php", "-S", f"127.0.0.1:{PORT}", "-t", str(ROOT / "app/public"), str(ROOT / "tests/router.php")],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    time.sleep(0.5)
    try:
        body = urllib.parse.urlencode({"code": "9difi12", "zone": "public", "mode": "edit",
                                       "expiry": "never", "content": SAMPLE}).encode()
        req = urllib.request.Request(BASE + "/new", data=body, method="POST", headers={"User-Agent": "shot"})
        urllib.request.urlopen(req).read()  # noqa: S310 (local test server)
        with sync_playwright() as p:
            browser = p.chromium.launch()
            page = browser.new_page(viewport={"width": 720, "height": 420})
            for name in themes:
                theme_file.write_text(name + "\n")
                page.goto(BASE + "/")
                page.locator("input[name=c]").blur()
                page.screenshot(path=str(out / f"{name}-home.png"))
                page.goto(BASE + "/9difi12")
                page.locator("#content").blur()
                page.wait_for_function("document.getElementById('status').textContent !== ''")
                page.screenshot(path=str(out / f"{name}-editor.png"))
                print("captured", name)
            browser.close()
    finally:
        server.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
