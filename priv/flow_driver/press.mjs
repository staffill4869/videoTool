// 생성 버튼을 직접 눌러 보고 90초간 화면 변화를 지켜본다.
import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];

page.on("dialog", async (d) => { console.log("대화상자:", d.message().slice(0, 100)); await d.dismiss(); });

const btn = page.getByRole("button", { name: /생성 시작/ }).first();
await btn.click();
console.log("눌렀음");

for (let i = 1; i <= 6; i++) {
  await page.waitForTimeout(15000);
  const s = await page.evaluate(() => ({
    imgs: document.querySelectorAll('img[src*="googleusercontent"],img[src*="lh3"]').length,
    toast: [...document.querySelectorAll('[role=alert],[role=status],.mat-mdc-snack-bar-label,snack-bar-container')]
      .map((e) => (e.textContent || "").trim().slice(0, 120)).filter(Boolean),
    empty: /미디어 만들기를 시작/.test(document.body.innerText),
  }));
  console.log(i * 15 + "초:", JSON.stringify(s));
  if (s.imgs > 1 || s.toast.length) break;
}
await page.screenshot({ path: "/tmp/press.png" });
await browser.close();
