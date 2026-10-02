// 프롬프트 입력칸을 먼저 잡고, 그 옆의 "소재 추가" 를 눌러 본다. 끝나면 Escape.
import { chromium } from "playwright-core";
import { readFile } from "node:fs/promises";

const cfg = JSON.parse(await readFile("./selectors.json", "utf8"));
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
console.log("URL:", page.url());

const box = page.locator(cfg.promptBox[0].css).first();
console.log("프롬프트칸 개수:", await page.locator(cfg.promptBox[0].css).count());
if (await box.count()) {
  await box.click().catch((e) => console.log("클릭 실패", e.message));
  await page.waitForTimeout(1200);
}

const names = await page.evaluate(() => {
  const txt = (el) => (el.getAttribute("aria-label") || el.title || el.textContent || "").trim().slice(0, 45);
  return [...document.querySelectorAll("button,[role=button]")].map(txt).filter(Boolean);
});
console.log("입력칸 활성화 후 버튼:", JSON.stringify(names.slice(0, 40)));

const add = page.getByRole("button", { name: /소재 추가|미디어 메뉴 추가/ }).first();
if (await add.count()) {
  await add.click().catch((e) => console.log("소재버튼 클릭 실패", e.message));
  await page.waitForTimeout(1800);
  const res = await page.evaluate(() => {
    const txt = (el) => (el.getAttribute("aria-label") || el.title || el.textContent || "").trim().slice(0, 45);
    return {
      files: [...document.querySelectorAll('input[type="file"]')].map((el) => ({ accept: el.accept, id: el.id, hidden: el.offsetParent === null })),
      items: [...document.querySelectorAll('[role=menuitem],[role=option],li,button')].map(txt).filter(Boolean).slice(0, 25),
    };
  });
  console.log("file input:", res.files.length, JSON.stringify(res.files));
  console.log("메뉴:", JSON.stringify(res.items));
}
await page.keyboard.press("Escape");
await page.waitForTimeout(400);
await page.keyboard.press("Escape");
await browser.close();
