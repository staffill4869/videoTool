import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
await page.setViewportSize({ width: 1400, height: 900 }).catch(() => {});
await page.goto("https://flow.google.com/tools/flow", { waitUntil: "domcontentloaded" }).catch(() => {});
await page.waitForTimeout(5000);
const links = await page.evaluate(() =>
  [...document.querySelectorAll("a[href*='/project/']")].map((a) => a.getAttribute("href")).slice(0, 12));
console.log("PROJECTS", JSON.stringify([...new Set(links)]));
await browser.close();
