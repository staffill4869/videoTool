import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
await page.goto("https://flow.google.com/project/6cf437c5-fb24-4f2a-8e57-b5d67e1eaaa7", { waitUntil: "domcontentloaded" });
await page.waitForTimeout(4000);
const r = await page.evaluate(() => {
  const bar = [...document.querySelectorAll("*")].filter((e) => {
    const t = (e.innerText || "").trim();
    return e.offsetParent && /Nano Banana|Veo|crop_/.test(t) && t.length < 80;
  });
  return bar.map((e) => {
    const b = e.getBoundingClientRect();
    return { tag: e.tagName, kids: e.children.length, t: (e.innerText || "").trim().replace(/\n/g, "|").slice(0, 60), x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) };
  });
});
console.log(JSON.stringify(r, null, 1));
await browser.close();
