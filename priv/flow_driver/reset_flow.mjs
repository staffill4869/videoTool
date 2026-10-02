// 에이전트(채팅) 패널을 닫고 영상 프롬프트 바로 되돌린다.
// 동의 팝업은 '나중에' 로만 넘긴다 — 사용자 계정에 약관을 대신 동의하지 않는다.
import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];

const later = page.getByRole("button", { name: /^나중에$/ });
if (await later.count()) { await later.first().click().catch(() => {}); await page.waitForTimeout(800); }

// 생성 중이면 멈춘다 — 채팅이 계속 돌면 입력칸이 잠겨 있다.
for (const n of [/중지/, /^stop$/i, /취소/]) {
  const b = page.getByRole("button", { name: n });
  if (await b.count()) { await b.first().click().catch(() => {}); await page.waitForTimeout(600); break; }
}

for (const name of [/^닫기$/, /^close$/i, /세션 닫기/]) {
  const b = page.getByRole("button", { name }).last();
  if (await b.count()) { await b.click().catch(() => {}); await page.waitForTimeout(1000); break; }
}
await page.waitForTimeout(1500);

const r = await page.evaluate(() => {
  const eds = [...document.querySelectorAll("[contenteditable='true'], textarea")]
    .filter((e) => e.offsetParent)
    .map((e) => (e.getAttribute("placeholder") || e.getAttribute("aria-label") || e.innerText || "").slice(0, 60));
  return {
    chatUi: !!document.querySelector('[aria-label="세션 기록 열기"], [aria-label="만족스러운 대답"]'),
    consent: /동의함/.test(document.body.innerText),
    editables: eds,
  };
});
console.log(JSON.stringify(r, null, 1));
await browser.close();
