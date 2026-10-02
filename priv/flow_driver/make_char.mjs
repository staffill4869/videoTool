// Flow 「캐릭터」에 이미지를 올려 등록한다. 인자: <파일경로> <이름>
import { chromium } from "playwright-core";

const [file, name] = process.argv.slice(2);
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];

// 캐릭터 만들기 화면으로. 주소를 직접 친다 — 메뉴 클릭은 화면 상태를 탄다.
const base = page.url().match(/^(https?:\/\/[^/]+\/project\/[^/]+)/);
if (!base) throw new Error("Flow 프로젝트 화면이 아닙니다: " + page.url());
await page.goto(base[1] + "/character", { waitUntil: "domcontentloaded", timeout: 30000 });
await page.waitForTimeout(3000);

// "업로드" 는 숨은 input[type=file] 을 연다. 파일 선택창이 뜨기 전에 가로챈다.
const chooser = page.waitForEvent("filechooser", { timeout: 15000 });
await page.getByRole("button", { name: /업로드/ }).first().click();
const fc = await chooser;
await fc.setFiles(file);
console.log("파일 올림:", file);
await page.waitForTimeout(6000);

await page.screenshot({ path: "/tmp/char_after.png" });
const state = await page.evaluate(() => {
  const txt = (el) => (el.getAttribute("aria-label") || el.title || el.textContent || "").trim().slice(0, 45);
  return {
    inputs: [...document.querySelectorAll("input[type=text],textarea,[contenteditable=true]")]
      .map((el) => ({ ph: el.placeholder || el.getAttribute("aria-label") || "", val: (el.value || el.textContent || "").slice(0, 30) })),
    buttons: [...document.querySelectorAll("button,[role=button]")].map(txt).filter(Boolean).slice(0, 25),
  };
});
console.log("입력칸:", JSON.stringify(state.inputs));
console.log("버튼:", JSON.stringify(state.buttons));
await browser.close();
