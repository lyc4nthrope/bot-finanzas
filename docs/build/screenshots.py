"""Screenshots of workflows/discord-interactions.json for docs/workflow.md.

Drives a throwaway n8n started by scripts/docs-screenshots.sh (never a real instance).
Env: N8N_URL, PW (throwaway owner password), WF (workflow id in that instance).
"""
import os, re
from playwright.sync_api import sync_playwright

B = os.environ["N8N_URL"]
NODES = ["Discord webhook", "Verify signature", "Is authentic?", "Reject 401", "Route",
         "Build PONG", "Record transaction", "Get summary", "Undo last",
         "Build unknown command", "Format reply", "Build database error", "Reply",
         "Acknowledge", "Build AI request", "Ask AI", "Validate AI output", "Is valid?",
         "Record AI transaction", "Format AI reply", "Build AI database error",
         "Build AI not understood", "Build AI unavailable", "Edit Discord message", "Build help"]

def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1600, "height": 900}, device_scale_factor=1.5)
    page.goto(f"{B}/signin")
    page.fill('input[type="email"]', "docs@example.com")
    page.fill('input[type="password"]', os.environ["PW"])
    page.keyboard.press("Enter")
    page.wait_for_url("**/home/**", timeout=30000)
    page.goto(f"{B}/workflow/{os.environ['WF']}")
    page.wait_for_selector('[data-test-id="canvas-node"]', timeout=30000)
    page.wait_for_timeout(3000)
    page.screenshot(path="/out/workflow-overview.png")
    print("ok workflow-overview.png")

    for index, name in enumerate(NODES, start=1):
        node = page.locator(f'[data-test-id="canvas-node"][data-node-name="{name}"]')
        node.dblclick()
        page.wait_for_selector('[data-test-id="ndv"]', timeout=15000)
        page.wait_for_timeout(1500)
        file = f"node-{index:02d}-{slug(name)}.png"
        page.screenshot(path=f"/out/{file}")
        print("ok", file)
        page.keyboard.press("Escape")
        page.wait_for_selector('[data-test-id="ndv"]', state="hidden", timeout=15000)
        page.wait_for_timeout(500)
    browser.close()
