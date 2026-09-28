#!/usr/bin/env python3
"""Browser test of the editor UI (autosave, conflict banner, delete, burn).

Runs php -S with tests/router.php and drives Chromium through Playwright.
Optional: needs `python3 -m pip install playwright && playwright install chromium`.
Usage: tests/ui_test.py [screenshot_dir]
"""

from __future__ import annotations

import base64
import hashlib
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

from playwright.sync_api import Page, sync_playwright

HERE = Path(__file__).resolve().parent
PORT = 8097
BASE = f"http://127.0.0.1:{PORT}"
results: list[tuple[str, bool]] = []


def check(name: str, ok: bool) -> None:
    results.append((name, ok))
    print(("ok   " if ok else "FAIL ") + name)


def raw(path: str) -> str:
    req = urllib.request.Request(BASE + path + "?raw", headers={"User-Agent": "test"})
    with urllib.request.urlopen(req) as res:  # noqa: S310 (local test server)
        return res.read().decode()


def post(path: str, data: dict[str, str]) -> None:
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(BASE + path, data=body, method="POST", headers={"User-Agent": "test"})
    urllib.request.urlopen(req).read()  # noqa: S310 (local test server)


def sha(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def wait_for(fn, timeout: float = 5.0) -> bool:  # type: ignore[no-untyped-def]
    end = time.time() + timeout
    while time.time() < end:
        if fn():
            return True
        time.sleep(0.1)
    return False


def main() -> int:
    shots = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    work = Path(tempfile.mkdtemp())
    for zone in ("public", "private"):
        (work / "data" / zone).mkdir(parents=True)
    (work / "secret").write_text(base64.b64encode(os.urandom(48)).decode())
    theme_file = work / "theme"
    env = dict(os.environ, CP_DATA_DIR=str(work / "data"), CP_SECRET_FILE=str(work / "secret"),
               CP_THEME_FILE=str(theme_file))
    server = subprocess.Popen(
        ["php", "-S", f"127.0.0.1:{PORT}", "-t", str(HERE.parent / "app/public"), str(HERE / "router.php")],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    time.sleep(0.5)
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch()
            page: Page = browser.new_page(viewport={"width": 1100, "height": 700})
            errors: list[str] = []
            page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.on("dialog", lambda d: d.accept())

            page.goto(BASE + "/")
            if shots:
                page.screenshot(path=str(shots / "1-home.png"))
            page.fill("input[name=c]", "nothere")
            page.click("button[type=submit]")
            check("home -> missing code gives 404 page", "Nothing here" in page.content())

            page.goto(BASE + "/new")
            page.fill("#code", "")
            page.click("#random")
            code = page.input_value("#code")
            check("random button fills a 7-char code", len(code) == 7)
            page.check("input[value=private]")
            check("private zone switches default expiry to never", page.input_value("#expiry") == "never")
            page.check("input[value=public]")
            check("public zone switches back to 7 days idle", page.input_value("#expiry") == "idle7d")
            page.fill("#code", "uitest")
            page.fill("#content", "hello")
            if shots:
                page.screenshot(path=str(shots / "3-new.png"), full_page=True)
            page.click("button.primary")
            check("create editable opens the note", page.url == BASE + "/uitest")
            check("editor shows initial content", page.input_value("#content") == "hello")
            if shots:
                page.goto(BASE + "/new/uitest")
                page.screenshot(path=str(shots / "4-settings.png"), full_page=True)

            page.goto(BASE + "/uitest")
            page.click("#content")
            page.keyboard.press("End")
            page.keyboard.type(" world")
            check("autosave reaches server", wait_for(lambda: raw("/uitest") == "hello world"))
            check("status shows Saved", wait_for(lambda: page.inner_text("#status") == "Saved"))
            if shots:
                page.screenshot(path=str(shots / "2-editor.png"))

            # Someone else saves; our next keystroke must hit the conflict path.
            req = urllib.request.Request(BASE + "/uitest?a=save", data=b"theirs", method="POST",
                                         headers={"User-Agent": "test", "Content-Type": "text/plain"})
            urllib.request.urlopen(req).read()  # noqa: S310
            page.keyboard.type("!")
            check("conflict banner appears", wait_for(lambda: page.is_visible("#conflict")))
            check("server keeps the other version", raw("/uitest") == "theirs")
            page.keyboard.type(" more")
            time.sleep(2)
            check("autosave paused during conflict", raw("/uitest") == "theirs")
            check("my text still in the box", page.input_value("#content") == "hello world! more")
            if shots:
                page.screenshot(path=str(shots / "5-conflict.png"))
            page.click("#reload")
            page.wait_for_load_state()
            check("reload shows server version", page.input_value("#content") == "theirs")

            # Share copies the canonical note URL (not ?raw or any query string).
            sharer = browser.new_context(permissions=["clipboard-read", "clipboard-write"]).new_page()
            sharer.on("pageerror", lambda e: errors.append(str(e)))
            sharer.goto(BASE + "/uitest?x=1")
            sharer.click("[data-share]")
            # The clipboard write is asynchronous: wait for the label instead of reading it at once.
            check("Share says the link was copied",
                  wait_for(lambda: sharer.inner_text("[data-share]") == "Link copied", 2.0))
            check("Share copies the canonical URL", sharer.evaluate("navigator.clipboard.readText()") == BASE + "/uitest")
            sharer.close()

            page.click("#delete")
            page.wait_for_url(BASE + "/")
            check("delete goes home", page.url == BASE + "/")
            check("note deleted", wait_for(
                lambda: subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", BASE + "/uitest"],
                                       capture_output=True, text=True).stdout == "404"))

            page.goto(BASE + "/new")
            page.fill("#code", "burnui")
            page.select_option("#mode", "burn")
            page.fill("#content", "secret once")
            page.click("button.primary")
            page.goto(BASE + "/burnui")
            if shots:
                page.screenshot(path=str(shots / "6-burn.png"))
            page.click("button.danger")
            check("burn reveal shows content", page.input_value("#content") == "secret once")
            check("reveal URL drops ?a=reveal", page.url == BASE + "/burnui")
            page.reload()
            check("reload after reveal shows friendly page", "Nothing here" in page.content())
            if shots:
                page.screenshot(path=str(shots / "7-burned.png"))
            page.goto(BASE + "/burnui")
            check("burned note is gone", "Nothing here" in page.content())

            page.goto(BASE + "/new")
            page.fill("#code", "pwui")
            page.fill("#password", "pw")
            page.fill("#content", "behind password")
            page.click("button.primary")
            check("owner lands in the editor, already unlocked",
                  page.url == BASE + "/pwui" and page.input_value("#content") == "behind password")
            visitor = browser.new_context().new_page()  # someone else: no unlock cookie
            visitor.on("pageerror", lambda e: errors.append(str(e)))
            visitor.goto(BASE + "/pwui")
            if shots:
                visitor.screenshot(path=str(shots / "8-unlock.png"))
            visitor.fill("#pw", "pw")
            visitor.click("button[type=submit]")
            check("unlock shows editor", visitor.input_value("#content") == "behind password")

            # --- live updates: two separate browser contexts behave like two machines
            def watch(pg: Page) -> Page:
                pg.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
                pg.on("pageerror", lambda e: errors.append(str(e)))
                pg.on("dialog", lambda d: d.accept())
                return pg

            poll_wait = 7.0  # one 3 s poll interval plus margin
            a = watch(browser.new_context().new_page())
            b = watch(browser.new_context().new_page())
            post("/new", {"code": "liveui", "zone": "public", "mode": "edit", "expiry": "never", "content": "start"})
            a.goto(BASE + "/liveui")
            b.goto(BASE + "/liveui")
            a.click("#content")
            a.keyboard.press("End")
            a.keyboard.type(" +A")
            check("A autosaves", wait_for(lambda: raw("/liveui") == "start +A"))
            check("B receives A's edit without reload", wait_for(lambda: b.input_value("#content") == "start +A", poll_wait))
            check("B shows Updated", b.inner_text("#status") == "Updated")
            b.click("#content")
            b.keyboard.press("End")
            b.keyboard.type(" +B")
            check("B can keep editing after an update", wait_for(lambda: raw("/liveui") == "start +A +B"))
            check("A receives B's edit", wait_for(lambda: a.input_value("#content") == "start +A +B", poll_wait))
            if shots:
                b.screenshot(path=str(shots / "9-live-updated.png"))

            # Unsaved local text in B (its saves are dropped) vs. a newer server copy.
            b.route("**/liveui?a=save", lambda route: route.abort())
            b.keyboard.type(" local")
            time.sleep(1.2)
            a.keyboard.type(" newer")
            check("A saves the newer copy", wait_for(lambda: raw("/liveui") == "start +A +B newer"))
            check("B shows conflict instead of overwriting", wait_for(lambda: b.is_visible("#conflict"), poll_wait))
            check("B keeps its unsaved text", b.input_value("#content") == "start +A +B local")
            check("server keeps A's copy", raw("/liveui") == "start +A +B newer")
            b.unroute("**/liveui?a=save")
            if shots:
                b.screenshot(path=str(shots / "10-live-conflict.png"))

            b.goto(BASE + "/liveui")
            a.click("#delete")
            a.wait_for_url(BASE + "/")
            check("B told the note is gone", wait_for(lambda: b.is_visible("#error") and "deleted" in b.inner_text("#error"), poll_wait))

            post("/new", {"code": "liveview", "zone": "public", "mode": "readonly", "expiry": "never", "content": "r1"})
            b.goto(BASE + "/liveview")
            post("/new/liveview?a=save", {"base": sha("r1"), "content": "r2", "mode": "readonly", "expiry": "never"})
            check("read-only view updates live", wait_for(lambda: b.input_value("#content") == "r2", poll_wait))

            # Octopus: animated by default, still for prefers-reduced-motion.
            page.goto(BASE + "/")
            anims = page.evaluate("document.querySelector('.octo.live').getAnimations({subtree: true}).length")
            check("octopus animates (body + 4 arms)", anims == 5)
            calm = browser.new_context(reduced_motion="reduce").new_page()
            calm.goto(BASE + "/")
            still = calm.evaluate("document.querySelector('.octo.live').getAnimations({subtree: true}).length")
            check("octopus is still for prefers-reduced-motion", still == 0)
            calm.close()

            # Every theme: entry page and editor load without CSP or script errors.
            post("/new", {"code": "themeui", "zone": "public", "mode": "edit", "expiry": "never", "content": "x"})
            themes = sorted(t.stem for t in (HERE.parent / "app/public/static/themes").glob("*.css"))
            bad = []
            for name in themes:
                theme_file.write_text(name + "\n")
                before = len(errors)
                page.goto(BASE + "/")
                ok_home = page.locator(f'link[href="/static/themes/{name}.css"]').count() == 1
                page.goto(BASE + "/themeui")
                ok_edit = page.inner_text("#status") != ""
                if not (ok_home and ok_edit) or len(errors) != before:
                    bad.append(name)
            theme_file.unlink()
            check(f"all {len(themes)} themes load cleanly", not bad)
            for name in bad:
                print("   theme:", name)

            # Expected 404/409 responses are logged by Chromium; anything else is a real error.
            errors = [e for e in errors if not e.startswith("Failed to load resource")]
            check("no console or CSP errors", not errors)
            for e in errors:
                print("   console:", e)
            browser.close()
    finally:
        server.terminate()
    failed = sum(1 for _, ok in results if not ok)
    print(f"\npassed: {len(results) - failed}  failed: {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
