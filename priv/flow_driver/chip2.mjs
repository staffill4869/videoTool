import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
await page.setViewportSize({ width: 1400, height: 900 }).catch(() => {});
const back = page.locator("button").filter({ hasText: /^arrow_back$/ }).first();
if (await back.count()) { await back.click().catch(() => {}); await page.waitForTimeout(1200); }
const chip = page.locator("button").filter({ hasText: /^에이전트$/ }).first();
console.log("chip", await chip.count());
if (await chip.count()) { await chip.click().catch((e) => console.log("err", e.message)); await page.waitForTimeout(1600); }
await page.screenshot({ path: "/tmp/mode.png" });
const txt = await page.evaluate(() =>
  [...document.querySelectorAll("[role=menuitem],[role=option],li,button")]
    .filter((e) => e.offsetParent).map((e) => (e.innerText || "").trim().replace(/\n/g, "|").slice(0, 50)).filter((t) => t.length > 1));
console.log(JSON.stringify([...new Set(txt)], null, 0));
await browser.close();
