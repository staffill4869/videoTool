import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
const info = await page.evaluate(() => {
  const out = { buttons: [], editables: [], chips: [] };
  for (const b of document.querySelectorAll("button")) {
    const t = (b.innerText || "").trim();
    const a = b.getAttribute("aria-label") || "";
    if (t || a) out.buttons.push({ t: t.slice(0, 40), a: a.slice(0, 40), dis: b.disabled });
  }
  for (const e of document.querySelectorAll("[contenteditable], textarea, input[type=text]")) {
    out.editables.push({ tag: e.tagName, ce: e.getAttribute("contenteditable"), ph: (e.getAttribute("placeholder") || e.getAttribute("aria-label") || e.innerText || "").slice(0, 50), vis: !!e.offsetParent });
  }
  return out;
});
console.log(JSON.stringify(info, null, 1));
await browser.close();
