// 오른쪽 에이전트 패널을 닫는다. 회수가 그 DOM 때문에 막힌다.
import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
for (const name of [/^닫기$/, /^close$/i, /세션 닫기/]) {
  const b = page.getByRole("button", { name }).last();
  if (await b.count()) { await b.click().catch(() => {}); await page.waitForTimeout(800); break; }
}
await page.waitForTimeout(1500);
const r = await page.evaluate(() => ({
  imgs: document.querySelectorAll('img[src*="googleusercontent"],img[src*="lh3"]').length,
  panel: /무엇을 만들고 싶으신가요\?/.test(document.body.innerText),
}));
console.log(JSON.stringify(r));
await browser.close();
