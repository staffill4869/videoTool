// "프롬프트 상자에 소재 추가" 를 눌러 **무엇이 열리는지만** 본다. 끝나면 Escape 로 되돌린다.
import { chromium } from "playwright-core";

const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
console.log("URL:", page.url());

const btn = page.getByRole("button", { name: /소재 추가/ }).first();
if (!(await btn.count())) {
  console.log("버튼 못 찾음");
} else {
  await btn.click();
  await page.waitForTimeout(1500);

  const after = await page.evaluate(() => {
    const txt = (el) => (el.getAttribute("aria-label") || el.title || el.textContent || "").trim().slice(0, 50);
    return {
      files: [...document.querySelectorAll('input[type="file"]')].map((el) => ({
        accept: el.accept, hidden: el.offsetParent === null, id: el.id, label: txt(el),
      })),
      menu: [...document.querySelectorAll('[role=menuitem],[role=option],button,[role=button]')]
        .map(txt).filter(Boolean).slice(0, 30),
    };
  });
  console.log("file input:", after.files.length, JSON.stringify(after.files));
  console.log("열린 항목:", JSON.stringify(after.menu));

  await page.keyboard.press("Escape");
  await page.waitForTimeout(500);
  await page.keyboard.press("Escape");
}
await browser.close();
