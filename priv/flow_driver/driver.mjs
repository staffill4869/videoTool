// Flow 조종기.
//
// 이미 사람이 로그인해 둔 Chrome 에 CDP 로 붙는다. 자격증명은 만지지 않고, 로그인도 하지 않는다.
// 한 번 호출에 한 동작만 하고 JSON 한 줄을 뱉는다 — 상주 프로세스를 두지 않기 위해서다.
//
//   node driver.mjs '{"action":"status"}'
//   node driver.mjs '{"action":"paste_and_generate","prompt":"..."}'
//   node driver.mjs '{"action":"wait_results","expect":18,"timeoutMs":900000}'
//   node driver.mjs '{"action":"download"}'
//
// 셀렉터는 selectors.json 에 있다. UI 가 바뀌면 이 파일이 아니라 그 파일을 고친다.

import { chromium } from "playwright-core";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const CDP = process.env.FLOW_CDP_URL || "http://localhost:9222";
const PROBE_MS = 4000;

function out(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function fail(error, stage) {
  out({ ok: false, error, stage });
  process.exit(0); // 호출자가 JSON 으로 판단한다. 비정상 종료 코드로 흘리지 않는다.
}

async function selectors() {
  return JSON.parse(await readFile(join(HERE, "selectors.json"), "utf8"));
}

// 후보를 위에서부터 시도해 처음 보이는 것을 쓴다.
async function locate(page, candidates, what, timeout = PROBE_MS) {
  const tried = [];

  for (const c of candidates) {
    let loc = null;
    if (c.role) {
      loc = page.getByRole(c.role, c.name ? { name: new RegExp(c.name, "i") } : {});
    } else if (c.css) {
      loc = page.locator(c.css);
    } else if (c.text) {
      loc = page.getByText(new RegExp(c.text, "i"));
    } else {
      continue;
    }

    tried.push(JSON.stringify(c));

    try {
      const first = loc.first();
      await first.waitFor({ state: "visible", timeout });
      return first;
    } catch {
      // 다음 후보
    }
  }

  throw new Error(
    `'${what}' 을 찾지 못했습니다. Flow UI 가 바뀌었을 수 있습니다. ` +
      `priv/flow_driver/selectors.json 의 후보를 고치세요. 시도한 것: ${tried.join(" / ")}`
  );
}

async function connect() {
  let browser;
  try {
    browser = await chromium.connectOverCDP(CDP, { timeout: 8000 });
  } catch {
    throw new Error(
      `Chrome 에 붙지 못했습니다 (${CDP}). launch-chrome.ps1 로 디버그 포트를 열어 Chrome 을 먼저 띄우세요.`
    );
  }
  return browser;
}

async function flowPage(browser, cfg, { open = true } = {}) {
  const pages = browser.contexts().flatMap((c) => c.pages());
  const found = pages.find((p) => p.url().includes("/tools/flow"));
  if (found) return found;

  if (!open) return null;

  const context = browser.contexts()[0];
  if (!context) throw new Error("Chrome 에 열린 창이 없습니다.");

  const page = await context.newPage();
  await page.goto(cfg.url, { waitUntil: "domcontentloaded", timeout: 60000 });
  return page;
}

// ── 동작 ────────────────────────────────────────────────────────

async function status(browser, cfg) {
  const pages = browser.contexts().flatMap((c) => c.pages());
  const page = await flowPage(browser, cfg, { open: false });

  if (!page) {
    return {
      ok: true,
      connected: true,
      flow_tab: false,
      open_tabs: pages.length,
      hint: "Flow 탭이 열려 있지 않습니다. 열고 로그인해 두세요."
    };
  }

  let promptBox = false;
  try {
    await locate(page, cfg.promptBox, "프롬프트 입력칸", 2000);
    promptBox = true;
  } catch {
    /* 로그인 안 됐거나 UI 가 바뀐 경우 */
  }

  return {
    ok: true,
    connected: true,
    flow_tab: true,
    url: page.url(),
    prompt_box: promptBox,
    hint: promptBox ? null : "입력칸이 안 보입니다. 로그인 상태이거나 UI 변경인지 확인하세요."
  };
}

async function pasteAndGenerate(browser, cfg, { prompt }) {
  if (!prompt || !prompt.trim()) throw new Error("프롬프트가 비었습니다.");

  const page = await flowPage(browser, cfg);
  await page.bringToFront();

  const box = await locate(page, cfg.promptBox, "프롬프트 입력칸");
  await box.click();

  // 키 입력을 흉내내지 않고 한 번에 넣는다. 프롬프트가 7천 자를 넘어 타이핑은 비현실적이다.
  await page.keyboard.press("ControlOrMeta+A");
  await page.keyboard.press("Delete");
  await page.keyboard.insertText(prompt);

  const before = await countResults(page, cfg);

  const button = await locate(page, cfg.generateButton, "생성 버튼");
  await button.click();

  return { ok: true, inserted_chars: prompt.length, results_before: before };
}

async function countResults(page, cfg) {
  for (const c of cfg.resultItem) {
    if (!c.css) continue;
    try {
      return await page.locator(c.css).count();
    } catch {
      /* 다음 */
    }
  }
  return 0;
}

async function waitResults(browser, cfg, { expect, timeoutMs = 900000, since = 0 }) {
  const page = await flowPage(browser, cfg, { open: false });
  if (!page) throw new Error("Flow 탭이 없습니다.");

  const deadline = Date.now() + timeoutMs;
  let last = -1;

  while (Date.now() < deadline) {
    const n = await countResults(page, cfg);
    if (n !== last) last = n;
    if (n - since >= expect) return { ok: true, results: n, waited_ms: timeoutMs - (deadline - Date.now()) };
    await page.waitForTimeout(5000);
  }

  return {
    ok: false,
    error: `${Math.round(timeoutMs / 1000)}초 안에 ${expect}개가 나오지 않았습니다 (현재 ${last}개).`,
    stage: "wait_results",
    results: last
  };
}

async function download(browser, cfg) {
  const page = await flowPage(browser, cfg, { open: false });
  if (!page) throw new Error("Flow 탭이 없습니다.");

  await page.bringToFront();
  const button = await locate(page, cfg.downloadButton, "다운로드 버튼");
  await button.click();

  // 메뉴가 뜨는 UI 면 '프로젝트 다운로드' 항목을 한 번 더 누른다. 없으면 그냥 넘어간다.
  try {
    const item = await locate(page, cfg.downloadAllMenuItem, "프로젝트 다운로드 항목", 2500);
    await item.click();
  } catch {
    /* 메뉴가 없는 UI */
  }

  // 파일은 Chrome 이 평소 폴더에 받는다. 그 뒤는 videoCRM 의 Downloads 감시가 처리한다.
  return { ok: true, note: "다운로드를 눌렀습니다. 파일은 Downloads 감시가 가져갑니다." };
}

// ── 진입점 ──────────────────────────────────────────────────────

const raw = process.argv[2];
if (!raw) fail("명령 JSON 이 없습니다.", "argv");

let cmd;
try {
  cmd = JSON.parse(raw);
} catch (e) {
  fail(`명령 JSON 을 읽지 못했습니다: ${e.message}`, "argv");
}

let browser;
try {
  const cfg = await selectors();
  browser = await connect();

  const result =
    cmd.action === "status"
      ? await status(browser, cfg)
      : cmd.action === "paste_and_generate"
        ? await pasteAndGenerate(browser, cfg, cmd)
        : cmd.action === "wait_results"
          ? await waitResults(browser, cfg, cmd)
          : cmd.action === "download"
            ? await download(browser, cfg)
            : null;

  if (result === null) fail(`알 수 없는 action: ${cmd.action}`, "dispatch");
  out(result);
} catch (e) {
  fail(e.message, cmd.action);
}

// connectOverCDP 로 붙은 브라우저는 close() 하지 않는다 — 사용자의 Chrome 이 닫힐 수 있다.
// 연결만 끊고 나간다. 프로세스가 끝나면 소켓도 닫힌다.
process.exit(0);