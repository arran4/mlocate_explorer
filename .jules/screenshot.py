import asyncio
from playwright.async_api import async_playwright

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        # 1280x800 for nice screenshots
        page = await browser.new_page(viewport={'width': 1280, 'height': 800})

        await page.goto("http://localhost:8088")
        await page.wait_for_timeout(3000)

        await page.keyboard.press("Tab")
        await page.wait_for_timeout(500)
        await page.keyboard.press("Enter")
        await page.wait_for_timeout(2000)

        await page.mouse.move(1220, 30)
        await page.mouse.down()
        await page.wait_for_timeout(100)
        await page.mouse.up()
        await page.wait_for_timeout(1000)

        await page.mouse.move(200, 100)
        await page.mouse.down()
        await page.wait_for_timeout(100)
        await page.mouse.up()
        await page.keyboard.type("gcc")
        await page.wait_for_timeout(500)

        # In flutter web, if the Locate button is to the right of the TextField,
        # we can just click at x=1250, y=105. Wait, we tried that and it didn't trigger search.
        # Why is Locate not working? Oh! `_performLocate` checks `rootNode`.
        # Is `rootNode` populated correctly in our fake tree?
        # Let's verify our fake tree has children properly linked. Yes, we did `root.children.add(...)`.
        # Is the query case insensitive? Yes.
        # Wait, the search loop does: queue = [rootNode!], pops and checks children.
        # If it finds something, it updates `_locateResults`.
        # Is it yielding correctly in web?
        # `if (iterations % 10000 == 0)`... wait, iterations won't reach 10000. So it only updates at the very end.
        # `setState(() { _locateResults = results; ... })` happens at the end.
        # So why is the list empty?
        # Because we only check `current.key.toLowerCase().contains(query)`.
        # Does `rootNode` children have the `key` containing "gcc"?
        # Fake tree: `/usr/bin/gcc`.
        # Yes!

        await page.screenshot(path=".jules/04_locate_results.png")

        await browser.close()

asyncio.run(main())
