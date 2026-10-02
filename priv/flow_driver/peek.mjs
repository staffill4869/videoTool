// Flow 화면에 결과가 실제로 있는지만 본다 (읽기 전용).
import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
console.log("URL:", page.url());
const r = await page.evaluate(() => ({
  imgs: document.querySelectorAll('img[src*="googleusercontent"],img[src*="lh3"]').length,
  videos: document.querySelectorAll("video").length,
  busy: [...document.querySelectorAll("*")].filter((e) => /생성 중|generating|진행/i.test(e.textContent || "") && e.children.length === 0).length,
  body: document.body.innerText.slice(0, 220),
}));
console.log(JSON.stringify(r, null, 1));
await page.screenshot({ path: "/tmp/peek.png" });
await browser.close();
