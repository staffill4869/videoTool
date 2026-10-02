// 방금 올린 캐릭터에 이름을 넣고 완료한다. 인자: <이름>
import { chromium } from "playwright-core";

const [name] = process.argv.slice(2);
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];

const box = page.locator('input[placeholder="캐릭터 이름"]').first();
if (await box.count()) {
  await box.click();
  await page.keyboard.press("Control+A");
  await page.keyboard.type(name);
  await page.waitForTimeout(800);
  console.log("이름 넣음:", name);
} else {
  console.log("이름칸 못 찾음");
}

const done = page.getByRole("button", { name: /^완료$/ }).first();
if (await done.count()) {
  await done.click();
  await page.waitForTimeout(4000);
  console.log("완료 누름. URL:", page.url());
}
await page.screenshot({ path: "/tmp/char_done.png" });
await browser.close();
