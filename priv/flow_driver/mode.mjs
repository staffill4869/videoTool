import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
const chip = page.getByRole("button", { name: /에이전트/ }).first();
console.log("chip count", await page.getByRole("button", { name: /에이전트/ }).count());
await chip.click().catch((e) => console.log("click err", e.message));
await page.waitForTimeout(1200);
const opts = await page.evaluate(() =>
  [...document.querySelectorAll("[role=menuitem],[role=option],li,button")]
    .filter((e) => e.offsetParent && (e.innerText || "").trim().length > 1 && (e.innerText || "").length < 40)
    .map((e) => (e.innerText || "").trim())
);
console.log(JSON.stringify([...new Set(opts)], null, 0));
await page.screenshot({ path: "/tmp/mode.png" });
await browser.close();
