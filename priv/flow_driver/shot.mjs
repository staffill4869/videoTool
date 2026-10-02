import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
await page.setViewportSize({ width: 1400, height: 900 }).catch(() => {});
await page.screenshot({ path: "/tmp/flow.png" });
console.log("ok", page.url());
await browser.close();
