import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
for (let i = 1; i <= 8; i++) {
  await page.waitForTimeout(15000);
  const t = await page.evaluate(() => {
    const btns = [...document.querySelectorAll("button")].filter((b) => b.offsetParent)
      .map((b) => (b.innerText || b.getAttribute("aria-label") || "").trim()).filter((x) => x && x.length < 25);
    return { url: location.href.slice(-40), tail: document.body.innerText.slice(-600).replace(/\n+/g, " | "), btns: [...new Set(btns)].slice(-18) };
  }).catch(() => null);
  console.log("T" + i, JSON.stringify(t));
  await page.screenshot({ path: `/tmp/w${i}.png` }).catch(() => {});
}
await browser.close();
