import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
await page.setViewportSize({ width: 1400, height: 1400 }).catch(() => {});
await page.goto("https://flow.google.com/project/6cf437c5-fb24-4f2a-8e57-b5d67e1eaaa7", { waitUntil: "domcontentloaded" });
await page.waitForTimeout(6000);
const hist = page.locator("button").filter({ hasText: /^menu$/ }).first();
if (await hist.count()) { await hist.click().catch(() => {}); await page.waitForTimeout(2500); }
const txt = await page.evaluate(() => document.body.innerText.slice(-4000));
console.log(txt);
await page.screenshot({ path: "/tmp/hist.png", fullPage: false });
await browser.close();
