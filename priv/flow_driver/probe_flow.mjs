// Flow 화면에 **이미지 첨부 칸**이 있는지 읽기만 한다. 아무것도 누르지 않는다.
import { chromium } from "playwright-core";

const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
console.log("URL:", page.url());

const found = await page.evaluate(() => {
  const txt = (el) => (el.getAttribute("aria-label") || el.title || el.textContent || "").trim().slice(0, 70);
  const files = [...document.querySelectorAll('input[type="file"]')].map((el) => ({
    accept: el.accept, hidden: el.offsetParent === null, label: txt(el), id: el.id,
  }));
  const words = ["이미지", "업로드", "참조", "첨부", "upload", "image", "reference", "ingredient", "소재", "프레임"];
  const buttons = [...document.querySelectorAll("button,[role=button]")]
    .map(txt)
    .filter((t) => t && words.some((w) => t.toLowerCase().includes(w.toLowerCase())))
    .slice(0, 25);
  return { files, buttons, allButtons: [...document.querySelectorAll("button,[role=button]")].map(txt).filter(Boolean).slice(0, 30) };
});

console.log("file input:", found.files.length, JSON.stringify(found.files));
console.log("이미지 관련 버튼:", JSON.stringify(found.buttons));
console.log("화면의 버튼들:", JSON.stringify(found.allButtons));
await browser.close();
