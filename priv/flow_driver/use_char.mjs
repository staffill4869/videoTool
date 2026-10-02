// 프롬프트 상자의 "+" (소재 추가) 를 눌러 등록한 캐릭터가 고를 수 있는지 본다.
import { chromium } from "playwright-core";

const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
const base = page.url().match(/^(https?:\/\/[^/]+\/project\/[^/]+)/)[1];
await page.goto(base, { waitUntil: "domcontentloaded", timeout: 30000 });
await page.waitForTimeout(3000);

const add = page.getByRole("button", { name: /프롬프트 상자에 소재 추가/ }).first();
console.log("소재추가 버튼:", await add.count());
if (await add.count()) {
  await add.click();
  await page.waitForTimeout(2000);
  const res = await page.evaluate(() => {
    const txt = (el) => (el.getAttribute("aria-label") || el.title || el.textContent || "").trim().slice(0, 40);
    return [...document.querySelectorAll('[role=menuitem],[role=option],[role=tab],button,[role=button]')]
      .map(txt).filter(Boolean).slice(0, 30);
  });
  console.log("열린 것:", JSON.stringify(res));
  await page.screenshot({ path: "/tmp/ingredient.png" });
}
await browser.close();
