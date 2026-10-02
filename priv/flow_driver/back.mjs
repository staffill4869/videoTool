// 낱장 상세 화면에 걸려 있으면 프로젝트 갤러리로 되돌린다.
import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
const base = page.url().match(/^(https?:\/\/[^/]+\/project\/[^/]+)/);
console.log("지금:", page.url());
await page.keyboard.press("Escape");
await page.waitForTimeout(800);
if (base) {
  await page.goto(base[1], { waitUntil: "domcontentloaded", timeout: 30000 });
  await page.waitForTimeout(3500);
}
const r = await page.evaluate(() => ({
  imgs: document.querySelectorAll('img[src*="googleusercontent"],img[src*="lh3"]').length,
  tiles: document.querySelectorAll('[role=button] img, .media-tile, [data-testid*=tile]').length,
  head: document.body.innerText.slice(0, 160),
}));
console.log("갤러리:", JSON.stringify(r));
await page.screenshot({ path: "/tmp/gal.png" });
await browser.close();
