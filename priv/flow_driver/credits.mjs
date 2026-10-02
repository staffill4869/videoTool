// 크레딧/오류 메시지가 화면에 있는지 본다. 프롬프트를 넣어 보고 버튼 상태도 확인한다.
import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];

const box = page.locator("[contenteditable='true']").first();
console.log("프롬프트칸:", await box.count());
if (await box.count()) {
  await box.click();
  await box.fill("");
  await page.keyboard.insertText("미니어처 인형이 동전 위에 서 있는 사진");
  await page.waitForTimeout(1500);
  console.log("넣은 글자:", (await box.innerText()).slice(0, 40));

  const btn = page.getByRole("button", { name: /생성 시작|generate/i }).first();
  console.log("생성버튼 개수:", await btn.count());
  if (await btn.count()) {
    const dis = await btn.evaluate((el) => el.disabled || el.getAttribute("disabled") === "true" || el.getAttribute("aria-disabled") === "true");
    console.log("버튼 비활성?:", dis);
  }
}
const texts = await page.evaluate(() => {
  const out = [];
  for (const el of document.querySelectorAll("*")) {
    const t = (el.textContent || "").trim();
    if (el.children.length === 0 && t && /크레딧|credit|한도|초과|부족|오류|error|실패|사용량/i.test(t)) out.push(t.slice(0, 70));
  }
  return [...new Set(out)].slice(0, 12);
});
console.log("경고/크레딧 문구:", JSON.stringify(texts));
await browser.close();
