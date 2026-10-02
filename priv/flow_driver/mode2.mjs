import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
const hit = await page.evaluate(() => {
  const el = [...document.querySelectorAll("*")].find(
    (e) => e.offsetParent && /Nano Banana/.test(e.innerText || "") && (e.innerText || "").length < 60 && e.children.length < 6
  );
  if (!el) return null;
  const r = el.getBoundingClientRect();
  return { tag: el.tagName, cls: el.className.slice(0, 80), x: r.x + r.width / 2, y: r.y + r.height / 2 };
});
console.log("CHIP", JSON.stringify(hit));
if (hit) {
  await page.mouse.click(hit.x, hit.y);
  await page.waitForTimeout(1500);
  const opts = await page.evaluate(() =>
    [...document.querySelectorAll("[role=menuitem],[role=option],li")]
      .filter((e) => e.offsetParent)
      .map((e) => (e.innerText || "").trim().replace(/\n/g, " | ").slice(0, 70))
      .filter((t) => t.length > 1)
  );
  console.log("OPTS", JSON.stringify([...new Set(opts)], null, 0));
  await page.screenshot({ path: "/tmp/mode.png" });
}
await browser.close();
