import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
const btn = page.locator("button", { hasText: "Nano Banana" }).first();
await btn.click();
await page.waitForTimeout(1800);
const opts = await page.evaluate(() =>
  [...document.querySelectorAll("[role=menuitem],[role=option],[role=radio],li,button")]
    .filter((e) => e.offsetParent)
    .map((e) => ({ r: e.getAttribute("role") || e.tagName, t: (e.innerText || "").trim().replace(/\n/g, "|").slice(0, 70) }))
    .filter((o) => o.t.length > 1)
);
console.log(JSON.stringify(opts, null, 0));
await page.screenshot({ path: "/tmp/mode.png" });
await browser.close();
