import asyncio
from playwright.async_api import async_playwright
import time
import os

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        # Use a mobile viewport size
        page = await browser.new_page(viewport={'width': 412, 'height': 915})

        await page.goto("http://localhost:8088")
        await page.wait_for_timeout(3000)

        await page.keyboard.press("Tab")
        await page.wait_for_timeout(500)
        await page.keyboard.press("Enter")
        await page.wait_for_timeout(2000)

        # Take start screen
        await page.screenshot(path=".jules/android_home.png")
        print("Captured android_home.png")

        # Open /usr directory
        await page.mouse.move(206, 230)
        await page.mouse.down()
        await page.wait_for_timeout(100)
        await page.mouse.up()
        await page.wait_for_timeout(1000)

        await page.screenshot(path=".jules/android_dir.png")
        print("Captured android_dir.png")

        # Locate mode
        # The locate button is at the top right, but maybe wrapped or pushed.
        # It's an action button in AppBar. Usually at width-50, y=30
        await page.mouse.move(362, 30)
        await page.mouse.down()
        await page.wait_for_timeout(100)
        await page.mouse.up()
        await page.wait_for_timeout(1000)

        await page.screenshot(path=".jules/android_locate.png")
        print("Captured android_locate.png")

        await browser.close()

asyncio.run(main())
