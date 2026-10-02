import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
await page.setViewportSize({ width: 1400, height: 900 }).catch(() => {});
const link = page.getByText("캐릭터", { exact: true }).first();
if (await link.count()) {
  await link.click();
  await page.waitForTimeout(2500);
  console.log("캐릭터 열림:", page.url());
} else {
  console.log("캐릭터 항목 못 찾음");
}
await page.screenshot({ path: "/tmp/flow2.png" });
const info = await page.evaluate(() => {
  const txt = (el) => (el.getAttribute("aria-label") || el.title || el.textContent || "").trim().slice(0, 45);
  return {
    files: [...document.querySelectorAll('input[type="file"]')].map((el) => ({ accept: el.accept, hidden: el.offsetParent === null })),
    buttons: [...document.querySelectorAll("button,[role=button]")].map(txt).filter(Boolean).slice(0, 25),
  };
});
console.log("file input:", info.files.length, JSON.stringify(info.files));
console.log("버튼:", JSON.stringify(info.buttons));
await browser.close();
