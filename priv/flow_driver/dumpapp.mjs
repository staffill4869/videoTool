import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
for (let i = 1; i <= 90; i++) {
  const r = await page.evaluate(() => {
    if (!/항상 승인/.test(document.body.innerText)) return null;
    const hits = [...document.querySelectorAll("*")]
      .filter((e) => (e.textContent || "").trim() === "항상 승인" && e.children.length === 0)
      .map((e) => {
        const chain = [];
        let n = e;
        for (let d = 0; d < 4 && n; d++) { chain.push(n.tagName + "." + (n.className || "").toString().slice(0, 50)); n = n.parentElement; }
        return { cls: (e.className || "").toString().slice(0, 60), chain, dim: /dimmed/.test((e.className || "").toString()) };
      });
    return { bubble: document.querySelectorAll(".agent-bubble").length, optLabel: document.querySelectorAll(".option-label").length, hits };
  }).catch(() => null);
  if (r) { console.log("FOUND", JSON.stringify(r, null, 1)); break; }
  await page.waitForTimeout(5000);
}
console.log("dump done");
await browser.close();
