// 승인창이 뜨면 '항상 승인' 을 누른다. 사용자가 명시적으로 지시했다 (2026-10-02).
// 한 번 누르면 이후 생성이 자동 승인돼 묶음 생성이 되살아난다.
import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
for (let i = 1; i <= 60; i++) {
  const b = page.getByRole("button", { name: /항상 승인/ });
  const n = await b.count().catch(() => 0);
  if (n) {
    await b.first().click().catch((e) => console.log("click err", e.message));
    console.log("CLICKED 항상 승인 at poll", i);
    await page.waitForTimeout(2000);
    const still = await page.getByRole("button", { name: /항상 승인/ }).count().catch(() => 0);
    console.log("remaining prompts:", still);
    if (!still) break;
  }
  await page.waitForTimeout(10000);
}
console.log("watcher done");
await browser.close();
