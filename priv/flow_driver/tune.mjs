import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
await page.setViewportSize({ width: 1400, height: 900 }).catch(() => {});
await page.locator("button", { hasText: /^tune$/ }).first().click().catch((e) => console.log("err", e.message));
await page.waitForTimeout(1800);
const opts = await page.evaluate(() =>
  [...document.querySelectorAll("[role=menuitem],[role=option],[role=radio],mat-option,li,button,[role=listbox] *")]
    .filter((e) => e.offsetParent)
    .map((e) => (e.innerText || "").trim().replace(/\n/g, "|").slice(0, 70))
    .filter((t) => t.length > 1)
);
console.log(JSON.stringify([...new Set(opts)], null, 0));
await page.screenshot({ path: "/tmp/mode.png" });
await browser.close();
