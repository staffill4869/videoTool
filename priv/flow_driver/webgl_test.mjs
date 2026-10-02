// Flow 가 WebGL 을 실제로 쓰는지, 없으면 화면이 깨지는지 본다.
import { chromium } from "playwright-core";
const browser = await chromium.connectOverCDP("http://127.0.0.1:9222");
const ctx = browser.contexts()[0];
const page = ctx.pages().find((p) => p.url().includes("flow.google.com")) || ctx.pages()[0];
const r = await page.evaluate(() => {
  const c = document.createElement("canvas");
  const gl = c.getContext("webgl2") || c.getContext("webgl");
  return {
    webgl: !!gl,
    renderer: gl ? gl.getParameter(gl.getExtension("WEBGL_debug_renderer_info")?.UNMASKED_RENDERER_WEBGL || gl.RENDERER) : null,
    canvases: document.querySelectorAll("canvas").length,
    videos: document.querySelectorAll("video").length,
    playing: [...document.querySelectorAll("video")].filter((v) => !v.paused).length,
  };
});
console.log(JSON.stringify(r));
await browser.close();
