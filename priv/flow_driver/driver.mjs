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
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
// localhost 로 두면 안 된다. Node 는 localhost 를 ::1(IPv6) 로 먼저 풀 수 있는데
// Chrome 의 디버그 포트는 127.0.0.1(IPv4) 에만 붙는다 — 그러면 간헐적으로 연결이 거부된다.
const CDP = process.env.FLOW_CDP_URL || "http://127.0.0.1:9222";
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

// Playwright 는 붙을 때 모든 타깃에 자동으로 attach 한다.
// 구글 로그인이 남기는 cross-origin iframe 타깃(accounts.google.com/RotateCookiesPage 등)에
// 걸리면 `<ws connected>` 직후 그대로 멈춘다 — 포트는 응답하는데 접속만 안 되는 모양이라
// "Chrome 이 안 떠 있나" 로 오진하기 쉽다. 붙기 전에 page 가 아닌 타깃을 치운다.
async function closeStuckTargets() {
  let list;
  try {
    const res = await fetch(`${CDP}/json/list`, { signal: AbortSignal.timeout(3000) });
    list = await res.json();
  } catch {
    return 0; // 목록을 못 읽으면 그냥 붙어본다. 여기서 실패시키지 않는다.
  }

  const stuck = list.filter((t) => t.type === "iframe" || t.type === "other");
  for (const t of stuck) {
    try {
      await fetch(`${CDP}/json/close/${t.id}`, { signal: AbortSignal.timeout(3000) });
    } catch {
      /* 못 닫아도 붙기는 해본다 */
    }
  }
  return stuck.length;
}

async function connect() {
  try {
    return await chromium.connectOverCDP(CDP, { timeout: 8000 });
  } catch {
    /* 아래에서 한 번 더 */
  }

  // 한 번 실패하면 걸린 타깃을 치우고 다시 시도한다.
  const cleaned = await closeStuckTargets();

  try {
    return await chromium.connectOverCDP(CDP, { timeout: 12000 });
  } catch {
    throw new Error(
      `Chrome 에 붙지 못했습니다 (${CDP}). ` +
        (cleaned > 0
          ? `걸린 타깃 ${cleaned}개를 치우고 다시 시도했는데도 실패했습니다. Chrome 을 껐다 켜보세요.`
          : "launch-chrome.ps1 로 디버그 포트를 열어 Chrome 을 먼저 띄우세요.")
    );
  }
}

// /tools/flow 는 마케팅 랜딩 페이지다 — 입력칸이 애초에 없다.
// 편집기는 그 아래 경로(/tools/flow/project/... 등)에 있다. 둘을 구별하지 않으면
// "로그인이 안 됐나 UI 가 바뀌었나" 로 엉뚱하게 진단하게 된다.
function classify(url) {
  if (/accounts\.google\.com/.test(url)) return "login";

  // flow.google.com 이라고 다 편집기가 아니다. /about 과 루트는 입력칸이 없는 소개·목록 화면이고,
  // 편집기는 /project/<id> 다. 이걸 구별하지 않으면 "로그인이 안 됐나 UI 가 바뀌었나" 로
  // 오진하고, 사람에게 프로젝트를 직접 열어달라고 하게 된다 — 자동화가 할 수 있는 일인데도.
  if (/flow\.google\.com\/project\//.test(url)) return "editor";
  if (/flow\.google\.com/.test(url)) return "landing";

  if (/\/tools\/flow\/?(\?|#|$)/.test(url)) return "landing";
  if (/\/tools\/flow\//.test(url)) return "editor";
  return "other";
}

async function flowPage(browser, cfg, { open = true } = {}) {
  const pages = browser.contexts().flatMap((c) => c.pages());
  // 편집기가 열려 있으면 그걸 쓴다. 랜딩만 있으면 차선으로 쓴다.
  const found =
    pages.find((p) => classify(p.url()) === "editor") ||
    pages.find((p) => classify(p.url()) === "landing");
  if (found) return found;

  if (!open) return null;

  const context = browser.contexts()[0];
  if (!context) throw new Error("Chrome 에 열린 창이 없습니다.");

  const page = await context.newPage();
  await page.goto(cfg.url, { waitUntil: "domcontentloaded", timeout: 60000 });
  return page;
}

// 쿠키 배너와 '새 기능' 모달이 입력칸 위를 덮는다. 있으면 치우고, 없으면 그냥 넘어간다.
// locate 와 달리 실패해도 예외를 던지지 않는다 — 없는 게 정상인 것들이다.
async function dismissOverlays(page, cfg) {
  const dismissed = [];
  for (const c of cfg.dismiss || []) {
    try {
      const btn = page.getByRole(c.role, { name: new RegExp(c.name, "i") }).first();
      await btn.waitFor({ state: "visible", timeout: 1200 });
      await btn.click({ timeout: 2000 });
      dismissed.push(c.name);
      await page.waitForTimeout(800);
    } catch {
      /* 안 떠 있으면 넘어간다 */
    }
  }
  return dismissed;
}

// ── 동작 ────────────────────────────────────────────────────────

async function status(browser, cfg) {
  const pages = browser.contexts().flatMap((c) => c.pages());
  const page = await flowPage(browser, cfg, { open: false });

  if (!page) {
    const login = pages.find((p) => classify(p.url()) === "login");
    return {
      ok: true,
      connected: true,
      flow_tab: false,
      page: login ? "login" : "none",
      open_tabs: pages.length,
      hint: login
        ? "구글 로그인 화면에 멈춰 있습니다. 사람이 직접 로그인하세요 — 자동화는 로그인하지 않습니다."
        : "Flow 탭이 열려 있지 않습니다. 열고 로그인해 두세요."
    };
  }

  const kind = classify(page.url());

  let promptBox = false;
  if (kind === "editor") {
    try {
      await locate(page, cfg.promptBox, "프롬프트 입력칸", 2000);
      promptBox = true;
    } catch {
      /* UI 가 바뀐 경우 */
    }
  }

  const hints = {
    login: "구글 로그인 화면입니다. 사람이 직접 로그인하세요 — 자동화는 로그인하지 않습니다.",
    landing:
      "Flow 소개·목록 화면입니다. 입력칸이 없는 게 정상입니다. new_project 로 편집기를 여세요 — 사람이 열 필요 없습니다.",
    other: "Flow 페이지가 아닙니다.",
    editor: promptBox ? null : "편집기인데 입력칸을 못 찾았습니다. selectors.json 의 promptBox 후보를 고치세요."
  };

  return {
    ok: true,
    connected: true,
    flow_tab: true,
    page: kind,
    url: page.url(),
    prompt_box: promptBox,
    hint: hints[kind]
  };
}

// videoTool 프로젝트마다 Flow 프로젝트를 따로 연다.
// 한 Flow 프로젝트에 계속 쌓으면 이전 편의 이미지가 섞여서 다음 단계가 엉뚱한 걸 집는다.
async function newProject(browser, cfg) {
  const pages = browser.contexts().flatMap((c) => c.pages());
  let page = pages.find((p) => /flow\.google\.com/.test(p.url()));

  if (!page) {
    const context = browser.contexts()[0];
    if (!context) throw new Error("Chrome 에 열린 창이 없습니다.");
    page = await context.newPage();
  }

  await page.bringToFront();
  await page.goto(cfg.url, { waitUntil: "domcontentloaded", timeout: 60000 });
  await page.waitForTimeout(3000);
  await dismissOverlays(page, cfg);

  const before = page.url();
  const button = await locate(page, cfg.newProjectButton, "새 프로젝트 버튼");
  await button.click();

  // 새 프로젝트로 넘어가면 URL 에 /project/<id> 가 붙는다.
  for (let i = 0; i < 30; i++) {
    await page.waitForTimeout(1000);
    if (/\/project\//.test(page.url()) && page.url() !== before) break;
  }

  await dismissOverlays(page, cfg);

  if (!/\/project\//.test(page.url())) {
    throw new Error(`새 프로젝트가 열리지 않았습니다. 현재 위치: ${page.url()}`);
  }

  return { ok: true, url: page.url() };
}

// 화면에 있는 결과물을 파일로 받아온다.
//
// Flow 의 다운로드 버튼을 누르지 않는다 — 버튼 위치가 자주 바뀌고 zip 으로 묶여 나와
// 어느 게 어느 장면인지 알 수 없다. 대신 <img>/<video> 의 주소를 그대로 받는다.
// 페이지 안에서 fetch 하면 CSP 에 막히므로 page.request 로 받는다(쿠키는 그대로 쓴다).
// 영상 타일은 **마우스를 올려야** <video> 가 생긴다. 그 전에는 포스터 이미지
// (flow-content.google/image/<id>)만 들고 있어서 화면 긁기로는 영상 주소를 못 얻는다.
// 실측: play_circle 아이콘이 48개 보이는데 <video> 태그는 1개뿐이었다.
// 포스터의 <id> 와 영상의 <id> 는 같지만 서명(Expires/KeyName)이 달라 경로만 바꿔 쓸 수 없다.
async function revealVideos(page, limit = 40) {
  const out = [];

  let tiles = [];
  try {
    tiles = await page.$$("div.container");
  } catch {
    return out;
  }

  let seen = 0;
  for (const t of tiles) {
    if (seen >= limit) break;

    let isVideoTile = false;
    try {
      isVideoTile = await t.evaluate(
        (el) => !!el.querySelector("img") && /play_circle/.test(el.innerText || "")
      );
    } catch {
      continue;
    }
    if (!isVideoTile) continue;

    seen += 1;

    try {
      await t.hover({ timeout: 2500 });
      await page.waitForTimeout(900);
      const src = await t.evaluate((el) => {
        const v = el.querySelector("video");
        return v ? v.src || v.currentSrc || "" : "";
      });
      if (src) out.push({ type: "video", src });
    } catch {
      /* 이 타일은 건너뛴다 */
    }
  }

  return out;
}

// Flow 의 결과물 주소는 **두 가지 형식**이다 (둘 다 실측):
//   https://flow.google.com/asb/<긴 토큰>              ← 영상이 주로 이쪽
//   https://flow-content.google/(image|video)/<uuid>   ← 이미지가 주로 이쪽
// 걸러야 하는 건 구글 썸네일(`...=s512-rw`)이다 — 남의 프로젝트 타일이 이 모양으로 섞여 들어왔다.
// UUID 만 받게 했다가 /asb/ 영상 8개를 전부 놓친 적이 있다. 형식을 좁히지 말고 썸네일만 배제한다.
function isResultUrl(src) {
  const path = String(src).split("?")[0];
  if (/=s\d+(-|$)/.test(path)) return false; // 구글 썸네일 크기 지정
  return /\/asb\//.test(path) || /flow-content\.google\/(image|video)\//.test(path);
}

// 정해진 Flow 프로젝트로 간다. 한 편은 한 프로젝트 안에서 끝내야 한다 —
// 단계마다 새로 열면 앞 단계 이미지가 없어 두 프레임을 이어 붙일 수 없고,
// 재시도할 때마다 빈 프로젝트가 쌓인다 (실제로 우수수 생겼다).
async function openUrl(browser, cfg, { url }) {
  if (!url) throw new Error("url 이 없습니다.");
  const page = await flowPage(browser, cfg, { open: false });
  if (!page) throw new Error("Flow 탭이 없습니다.");

  if (page.url().split("?")[0] !== url.split("?")[0]) {
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 45000 });
    await page.waitForTimeout(2500);
  }
  await dismissOverlays(page, cfg);
  return { ok: true, url: page.url() };
}

async function harvest(browser, cfg, { dir, kind = "all", known = [] }) {
  if (!dir) throw new Error("harvest 에는 저장할 dir 이 필요합니다.");
  await mkdir(dir, { recursive: true });

  const page = await flowPage(browser, cfg, { open: false });
  if (!page) throw new Error("Flow 탭이 없습니다.");
  await page.bringToFront();
  await page.waitForTimeout(800);

  // 가상 스크롤 때문에 화면 밖 타일은 DOM 에 없다. 끝까지 훑는다.
  const seen = new Map();
  const collect = async () => {
    const items = await page.evaluate(() => {
      const out = [];
      for (const v of document.querySelectorAll("video")) {
        const src = v.src || v.currentSrc;
        if (src) out.push({ type: "video", src });
      }
      // 결과 주소는 바뀐다. 2026-09-10 엔 flow-content.google, 09-11 엔 flow.google.com/asb/ 였다.
      // 호스트로 좁히지 말고 '결과물 경로' 로 잡는다.
      // 크기로 거르지 않는다. 예전엔 '폭 200px 초과' 만 담았는데, 채팅 안에 작게 깔린
      // 썸네일이 전부 걸러져 화면엔 16장이 보이는데 0장을 가져왔다.
      // 세는 쪽(countResults)과 가져오는 쪽의 기준이 다르면 "다 됐다는데 빈손" 이 된다.
      // 아이콘만 피하면 충분하다 — /asb/ 경로 자체가 이미 결과물이라는 뜻이다.
      for (const i of document.querySelectorAll('img[src*="/asb/"], img[src*="flow-content.google"]')) {
        if (i.getBoundingClientRect().width >= 32) out.push({ type: "image", src: i.src });
      }
      return out;
    });

    for (const it of items) {
      // 서명된 주소라 만료 파라미터가 붙는다. 경로 마지막 조각이 실제 식별자다.
      const id = it.src.split("?")[0].split("/").pop();
      // **UUID 형태만 받는다.** 구글 썸네일(`...=s512-rw`)이 같은 셀렉터에 걸려
      // 남의 프로젝트 타일 6장을 우리 자산으로 등록한 적이 있다.
      // 진짜 생성물의 식별자는 언제나 UUID 다.
      if (id && isResultUrl(it.src) && !seen.has(id)) seen.set(id, it);
    }
  };

  await collect();
  for (let i = 0; i < 20; i++) {
    await page.mouse.move(700, 500);
    await page.mouse.wheel(0, 900);
    await page.waitForTimeout(400);
    await collect();
  }

  // 영상은 타일에 마우스를 올려야 주소가 드러난다. 이미지 단계에서는 빈 배열이라 비용이 없다.
  if (kind === "all" || kind === "video") {
    for (const it of await revealVideos(page)) {
      const id = it.src.split("?")[0].split("/").pop();
      if (id && isResultUrl(it.src) && !seen.has(id)) seen.set(id, it);
    }
  }

  const knownSet = new Set(known);
  const wanted = [...seen.entries()].filter(
    ([id, it]) => !knownSet.has(id) && (kind === "all" || it.type === kind)
  );

  const files = [];
  for (const [id, it] of wanted) {
    const ext = it.type === "video" ? "mp4" : "png";
    const path = join(dir, `${id}.${ext}`);
    try {
      const res = await page.request.get(it.src, { headers: { referer: page.url() }, timeout: 120000 });
      if (!res.ok()) continue;
      await writeFile(path, await res.body());
      files.push({ id, path, type: it.type });
    } catch {
      /* 한 장 실패해도 나머지는 받는다 */
    }
  }

  return { ok: true, files, seen: seen.size, skipped: seen.size - wanted.length };
}

// 프로젝트에 상시 지시를 박는다.
//
// 프롬프트 본문에 "9:16" 이라고 써도 에이전트가 무시하고 가로로 만들었다 (실측).
// 매번 지켜야 하는 것은 본문이 아니라 여기에 넣어야 한다 — 프로젝트 전체에 적용된다.
async function setGuideline(browser, cfg, { title = "제작 규칙", text }) {
  if (!text) throw new Error("setGuideline 에는 text 가 필요합니다.");

  const page = await flowPage(browser, cfg, { open: false });
  if (!page) throw new Error("Flow 탭이 없습니다.");
  await page.bringToFront();
  await page.keyboard.press("Escape");
  await page.waitForTimeout(500);

  // 패널이 이미 열려 있으면 트리거는 화면에서 사라진다. 그때 트리거를 찾으면 실패한다 —
  // 열려 있는지부터 보고, 닫혀 있을 때만 연다.
  let body = await find(page, cfg.guidelineBody, 1000);

  if (!body) {
    const trigger = await locate(page, cfg.guidelineTrigger, "에이전트 요청 사항 버튼");
    await trigger.click();
    await page.waitForTimeout(1200);
    body = await find(page, cfg.guidelineBody);
  }

  // 빈 칸이 없으면 하나 만든다. 이미 있으면 그걸 덮어쓴다 —
  // 부를 때마다 새로 추가하면 같은 지시가 쌓인다.
  if (!body) {
    const add = await locate(page, cfg.guidelineAdd, "안내 추가 버튼");
    await add.click();
    await page.waitForTimeout(1000);
    body = await locate(page, cfg.guidelineBody, "가이드라인 입력칸");
  }

  const titleBox = await find(page, cfg.guidelineTitle);
  if (titleBox) {
    await titleBox.fill("").catch(() => {});
    await titleBox.fill(title).catch(() => {});
  }

  await body.fill("").catch(() => {});
  await body.fill(text);
  await page.waitForTimeout(400);

  const done = await locate(page, cfg.guidelineDone, "완료 버튼");
  await done.click();
  await page.waitForTimeout(1000);

  return { ok: true, title, chars: text.length };
}

// locate 와 같지만 못 찾으면 예외 대신 null. 있으면 쓰고 없으면 만드는 흐름에 쓴다.
async function find(page, candidates, timeout = 1500) {
  try {
    return await locate(page, candidates, "", timeout);
  } catch {
    return null;
  }
}

// 입력칸을 누른다. Flow 는 크레딧 비용 안내(cdk-overlay-container 의 credit-cost-label)를
// 입력칸 위에 띄우는데, 그게 포인터를 가로채 클릭이 30초 타임아웃으로 죽는다.
// 오버레이를 닫아 보고, 그래도 막히면 가로채기를 무시하고 누른다.
async function clickBox(page, box) {
  try {
    await box.click({ timeout: 8000 });
    return;
  } catch {
    /* 아래에서 치우고 다시 */
  }

  await page.keyboard.press("Escape").catch(() => {});
  await page.mouse.move(10, 10).catch(() => {});
  await page.waitForTimeout(500);

  try {
    await box.click({ timeout: 8000 });
    return;
  } catch {
    /* 마지막 수단 */
  }

  // force 는 "가로채는 요소가 있어도 그냥 누른다". 좌표가 맞으면 입력칸에 들어간다.
  await box.click({ force: true, timeout: 8000 });
}

async function pasteAndGenerate(browser, cfg, { prompt }) {
  if (!prompt || !prompt.trim()) throw new Error("프롬프트가 비었습니다.");

  const page = await flowPage(browser, cfg);
  await page.bringToFront();

  // /project/<id>/edit/<...> 는 **낱장 편집 화면**이다. 여러 장 생성이 안 되고,
  // 프롬프트를 넣으면 "7번 이미지 (요약): ..." 처럼 설명만 쓰고 끝난다.
  // classify 는 /project/ 만 보고 editor 로 판단하므로 여기서 따로 걸러 되돌아간다.
  const edit = page.url().match(/^(https?:\/\/[^/]+\/project\/[^/]+)\/edit\//);
  if (edit) {
    await page.goto(edit[1], { waitUntil: "domcontentloaded", timeout: 30000 }).catch(() => {});
    await page.waitForTimeout(2500);
  }

  await dismissOverlays(page, cfg);

  const box = await locate(page, cfg.promptBox, "프롬프트 입력칸");
  await clickBox(page, box);

  // Ctrl+A → Delete 를 쓰지 않는다. 포커스가 입력칸 밖에 있으면 미디어 그리드가 전체 선택되고
  // 이어지는 Delete 가 생성물을 휴지통으로 보낸다 — 실제로 한 번 지웠다.
  // 비우기는 요소 안으로 범위가 한정되는 fill 로만 한다.
  await box.fill("").catch(() => {});

  // 포커스가 정말 입력칸 안에 있는지 확인하고 나서 넣는다.
  const focused = await box.evaluate((el) => el === document.activeElement || el.contains(document.activeElement));
  if (!focused) throw new Error("프롬프트 입력칸에 포커스가 잡히지 않았습니다. UI 가 바뀌었는지 확인하세요.");

  // 키 입력을 흉내내지 않고 한 번에 넣는다. 프롬프트가 7천 자를 넘어 타이핑은 비현실적이다.
  await page.keyboard.insertText(prompt);

  const before = await countResults(page, cfg);

  // 글자를 넣자마자 누르면 버튼이 아직 disabled 다 (실측: aria-label='생성 시작' 이
  // disabled="true" 인 채로 30초 타임아웃). 에디터가 변경을 반영할 때까지 기다린다.
  const button = await locate(page, cfg.generateButton, "생성 버튼");
  for (let i = 0; i < 20; i++) {
    const off = await button.evaluate((el) => el.disabled || el.getAttribute("disabled") === "true").catch(() => false);
    if (!off) break;
    await page.waitForTimeout(500);
  }

  await button.click({ timeout: 15000 });

  // 생성 **전에** 화면에 있던 id 를 함께 돌려준다. 회수 때 이걸 빼야
  // 남의 프로젝트 이미지를 가져오지 않는다 — INFO 단계에서 Flow 가 편집 화면(/edit/)으로
  // 넘어가면 다른 프로젝트 자산까지 22장이 깔려 있었고, 그중 6장을 우리 것으로 등록했다.
  const idsBefore = await resultIds(page);

  return { ok: true, inserted_chars: prompt.length, results_before: before, ids_before: idsBefore };
}

// 화면에 있는 결과물의 **id** 를 모은다. 개수가 아니라 id 로 세야 하는 이유:
// INFO 단계는 기존 이미지를 편집하는 작업이라 타일 개수가 늘지 않는다. 개수로 기다리면
// "16 + 16 = 32개" 를 영원히 못 채우고 15분을 버린 뒤 실패한다 (실제로 그랬다).
// 회수(harvest)가 쓰는 기준과 같게 맞춘다 — 두 곳의 기준이 다르면 반드시 어긋난다.
async function resultIds(page) {
  if (classify(page.url()) !== "editor") return [];

  try {
    return await page.evaluate(() => {
      const ids = new Set();
      const add = (src) => {
        if (!src) return;
        const id = src.split("?")[0].split("/").pop();
        if (id) ids.add(id);
      };
      for (const v of document.querySelectorAll("video")) add(v.src || v.currentSrc);
      for (const i of document.querySelectorAll('img[src*="/asb/"], img[src*="flow-content.google"]')) {
        if (i.getBoundingClientRect().width >= 32) add(i.src);
      }
      return [...ids];
    });
  } catch {
    return [];
  }
}

async function countResults(page, cfg) {
  // **편집기에서만 센다.** 홈 화면에는 프로젝트 썸네일이 같은 /asb/ 주소로 깔려 있어서
  // 그걸 생성 결과로 셌다. 재시도할수록 프로젝트가 늘어 썸네일이 늘고, 개수가 목표를
  // 넘는 순간 "다 만들어졌다" 며 빈손으로 빠져나왔다 (실측: 홈 화면에서 15개).
  if (classify(page.url()) !== "editor") return 0;

  // 후보는 구체적인 것부터 차례로 본다. 처음으로 0이 아닌 값을 쓴다 —
  // 가장 느슨한 후보의 값을 섞으면 화면 장식까지 세게 된다.
  for (const c of cfg.resultItem) {
    if (!c.css) continue;
    try {
      const n = await page.locator(c.css).count();
      if (n > 0) return n;
    } catch {
      /* 다음 후보 */
    }
  }
  return 0;
}

// Flow 는 생성이 끝나면 "다음 작업을 위해 무엇을 도와드릴까요?" 와 함께 선택지를 낸다.
// 이걸 '아직 덜 됐다' 로 오해하면 정해진 문장을 던지게 되고, 그러면 첫 번째 선택지
// ('생성된 이미지로 영상 만들기')를 고른 셈이 되어 시키지도 않은 영상이 만들어진다.
async function seesDoneMarker(page, cfg) {
  for (const c of cfg.doneMarker || []) {
    if (!c.text) continue;
    try {
      const loc = page.getByText(new RegExp(c.text, "i")).first();
      if (await loc.isVisible({ timeout: 600 })) return true;
    } catch {
      /* 다음 후보 */
    }
  }
  return false;
}

// 화면에 떠 있는 선택지들의 글자를 읽어 온다. 무엇을 묻는지 알아야 답을 고를 수 있다.
async function readChoices(page, cfg) {
  const out = [];
  for (const c of cfg.choiceOption || []) {
    if (!c.css) continue;
    try {
      const loc = page.locator(c.css);
      const n = Math.min(await loc.count(), 8);
      for (let i = 0; i < n; i++) {
        const item = loc.nth(i);
        if (!(await item.isVisible({ timeout: 300 }).catch(() => false))) continue;
        const text = ((await item.innerText().catch(() => "")) || "").trim();
        if (text) out.push({ text, item });
      }
      if (out.length) return out;
    } catch {
      /* 다음 후보 */
    }
  }
  return out;
}

// 원하는 선택지가 있으면 눌러 준다. 없으면 아무것도 누르지 않는다 —
// 아무거나 누르면 크레딧이 엉뚱한 데로 나간다.
async function clickChoice(page, cfg, wantPattern) {
  if (!wantPattern) return null;
  const re = new RegExp(wantPattern, "i");
  for (const { text, item } of await readChoices(page, cfg)) {
    if (!re.test(text)) continue;
    try {
      await item.click({ timeout: 3000 });
      return text;
    } catch {
      /* 다음 */
    }
  }
  return null;
}

async function waitResults(browser, cfg, { expect, timeoutMs = 900000, since = 0, stage = "", known = [] }) {
  const page = await flowPage(browser, cfg, { open: false });
  if (!page) throw new Error("Flow 탭이 없습니다.");

  // 편집기가 아니면 셀 것도, 기다릴 것도 없다. 여기서 바로 알려야 조용히 빈손으로 끝나지 않는다.
  if (classify(page.url()) !== "editor") {
    return {
      ok: false,
      error: `편집기가 아닌 화면입니다 (${page.url()}). 프로젝트를 먼저 열어야 합니다.`,
      stage: "wait_results",
      results: 0
    };
  }

  // 시작 시점에 이미 있던 id 를 기준선으로 잡는다. 이후 '새로 생긴 id' 만 센다 —
  // 개수로 세면 INFO 처럼 제자리에서 바뀌는 단계를 영원히 못 끝낸다.
  const baseline = new Set([...(known || []), ...(await resultIds(page))]);

  const deadline = Date.now() + timeoutMs;
  let last = -1;
  let stalls = 0;
  let confirmed = 0;
  let approvals = 0;
  const chose = [];

  while (Date.now() < deadline) {
    // 기준선에 없던 id 의 개수 = 이번 단계에서 새로 만들어진 것.
    const fresh = (await resultIds(page)).filter((id) => !baseline.has(id));
    const n = fresh.length;
    if (n !== last) last = n;
    if (n >= expect) {
      return {
        ok: true,
        results: n,
        confirmed,
        approvals,
        chose,
        waited_ms: timeoutMs - (deadline - Date.now())
      };
    }

    // 크레딧을 쓰기 전에 '승인 / 항상 승인 / 거부' 를 물으며 멈춘다.
    // 물을 때마다 사람을 부르면 무인 운전이 아니다. '항상 승인' 을 눌러 다시 묻지 않게 한다.
    if (await approveIfAsked(page, cfg)) {
      approvals += 1;
      stalls = 0;
      await page.waitForTimeout(2000);
      continue;
    }

    // 이 단계에서 원하는 선택지가 떠 있으면 글로 답하지 말고 그걸 누른다.
    // (영상 단계에서 '생성된 이미지로 영상 만들기' 가 바로 그 경우다)
    const want = (cfg.stageChoice || {})[stage];
    if (want) {
      const picked = await clickChoice(page, cfg, want);
      if (picked) {
        chose.push(picked);
        stalls = 0;
        await page.waitForTimeout(3000);
        continue;
      }
    }

    // "생성이 모두 완료되었습니다" 가 떴으면 이 단계는 끝난 것이다.
    // 여기서 아무 말도 하지 않고 빠져나온다 — 답하면 첫 선택지를 고른 셈이 된다.
    //
    // 결과가 한 장이라도 나온 뒤에만 인정한다. 새로 연 빈 프로젝트의 인사말을
    // 완료로 읽고 이미지 0장으로 끝낸 적이 있다 — 글자만 믿지 않는다.
    if (n > 0 && (await seesDoneMarker(page, cfg))) {
      return {
        ok: true,
        results: n,
        confirmed,
        approvals,
        chose,
        finished_by: "done_marker",
        waited_ms: timeoutMs - (deadline - Date.now())
      };
    }

    // 생성 중이면 정지 버튼이 떠 있다. 안 떠 있는데 결과가 모자라면 멈춰 선 것이다 —
    // 새 Flow 는 구성안을 내고 확인을 기다리므로, 한 번은 진행 confirm 을 보내본다.
    const busy = await isBusy(page, cfg);
    if (busy) {
      stalls = 0;
    } else if (++stalls >= 3 && confirmed < 2) {
      // 무엇을 묻든 "네, 그대로 진행해 주세요" 를 던지면 안 된다.
      // 생성이 끝난 뒤 Flow 는 '다음에 뭘 할까요? (1) 영상 만들기 …' 를 묻는데,
      // 거기에 "네" 라고 답하면 1번을 고른 셈이 되어 시키지도 않은 영상이 만들어진다.
      // 실제로 CLEAN 단계에서 영상 18개를 만들려 한 원인이 이것이었다.
      const produced = last;
      const msg =
        produced > 0
          ? (cfg.nudgeText || "아직 {N}개가 모자랍니다. 모자란 것만 이어서 만들어 주세요. 영상으로 만들지 말고 이 단계에서 멈추세요.")
              .replace("{N}", String(Math.max(expect - produced, 0)))
          : cfg.confirmText || "네, 그대로 진행해 주세요.";

      await sendMessage(page, cfg, msg);
      confirmed += 1;
      stalls = 0;
      await page.waitForTimeout(4000);
    }

    await page.waitForTimeout(5000);
  }

  return {
    ok: false,
    error: `${Math.round(timeoutMs / 1000)}초 안에 ${expect}개가 나오지 않았습니다 (현재 ${last}개).`,
    stage: "wait_results",
    results: last,
    confirmed,
    approvals,
    chose
  };
}

// 승인창이 떠 있으면 '항상 승인' 을 누른다. 없으면 false.
//
// '승인' 이 아니라 '항상 승인' 을 먼저 찾는 이유: 승인은 이번 한 번뿐이라 다음 단계에서 또 멈춘다.
// 돈이 나가는 결정이라 dismiss(덮개 치우기)와 섞지 않고 따로 둔다 — 같은 목록에 넣으면
// 덮개인 줄 알고 눌러버리는 사고가 난다 (Get started 를 dismiss 에 넣었다가 겪었다).
async function approveIfAsked(page, cfg) {
  // 승인 항목은 버튼이 아니다 — `div.agent-bubble` 안의 `span.option-label` 이다
  // (role 도 없고 <button> 도 아니라 getByRole 로는 영영 못 찾는다).
  // 같은 글자가 화면 여러 곳에 있으므로(우리가 보낸 답장까지) 반드시
  // **에이전트 말풍선 안에서, 아직 쓰이지 않은(dimmed 아닌) 것, 가장 마지막 것**을 누른다.
  for (const want of ["항상 승인", "승인", "Always allow", "Always approve", "Approve", "Allow"]) {
    const clicked = await page
      .evaluate((label) => {
        const opts = [...document.querySelectorAll(".agent-bubble .option-label")].filter(
          (e) => (e.textContent || "").trim() === label
        );
        const live = opts.filter((e) => !e.classList.contains("dimmed"));
        const target = (live.length ? live : opts).pop();
        if (!target) return false;

        // 실제로 눌리는 건 가까운 조상일 수 있다. 위로 올라가며 눌러 본다.
        let n = target;
        for (let d = 0; d < 4 && n; d++) {
          if (n.getBoundingClientRect().width > 0) {
            n.click();
            return true;
          }
          n = n.parentElement;
        }
        return false;
      }, want)
      .catch(() => false);

    if (clicked) return true;
  }

  // 예전 방식도 남겨 둔다 — UI 가 버튼으로 돌아갈 수 있다.
  for (const list of [cfg.approveAlways, cfg.approveOnce]) {
    if (!list || !list.length) continue;

    let btn = null;
    try {
      btn = await locate(page, list, "승인 버튼", 800);
    } catch {
      continue;
    }

    try {
      await btn.click({ timeout: 3000 });
      return true;
    } catch {
      /* 다음 목록 */
    }
  }

  return false;
}

async function isBusy(page, cfg) {
  for (const c of cfg.busy || []) {
    if (!c.css) continue;
    try {
      if ((await page.locator(c.css).count()) > 0) return true;
    } catch {
      /* 다음 */
    }
  }
  return false;
}

// 프롬프트 상자에 한 줄 넣고 보낸다. 전체 프롬프트를 다시 붙이지 않는다.
async function sendMessage(page, cfg, text) {
  const box = await locate(page, cfg.promptBox, "프롬프트 입력칸");
  await box.click();
  await page.keyboard.insertText(text);
  const button = await locate(page, cfg.generateButton, "생성 버튼");
  await button.click();
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

  // 파일은 Chrome 이 평소 폴더에 받는다. 그 뒤는 videoTool 의 Downloads 감시가 처리한다.
  return { ok: true, note: "다운로드를 눌렀습니다. 파일은 Downloads 감시가 가져갑니다." };
}

// ── 진입점 ──────────────────────────────────────────────────────

// 명령은 두 가지로 받는다.
//   node driver.mjs '{"action":"status"}'          ← 짧은 명령. 손으로 칠 때.
//   node driver.mjs --file C:\...\cmd.json         ← 긴 프롬프트. 서버는 항상 이쪽.
// argv 로 7천 자짜리 프롬프트를 넘기면 Windows 인용 처리에서 큰따옴표가 깨진다.
let raw;
if (process.argv[2] === "--file") {
  const p = process.argv[3];
  if (!p) fail("--file 뒤에 경로가 없습니다.", "argv");
  try {
    raw = await readFile(p, "utf8");
  } catch (e) {
    fail(`명령 파일을 읽지 못했습니다 (${p}): ${e.message}`, "argv");
  }
} else {
  raw = process.argv[2];
}

if (!raw) fail("명령 JSON 이 없습니다.", "argv");

let cmd;
try {
  cmd = JSON.parse(raw);
} catch (e) {
  fail(`명령 JSON 을 읽지 못했습니다: ${e.message}`, "argv");
}

// 브라우저 없이 도는 검사. classify 가 랜딩과 편집기를 뒤바꾸면 진단이 통째로 틀어진다.
if (cmd.action === "selftest") {
  const cases = [
    ["https://labs.google/fx/ko/tools/flow", "landing"],
    ["https://labs.google/fx/ko/tools/flow/", "landing"],
    ["https://labs.google/fx/ko/tools/flow?hl=ko", "landing"],
    ["https://labs.google/fx/ko/tools/flow/project/abc123", "editor"],
    // 홈·소개는 편집기가 아니다. 입력칸이 없으니 landing 으로 보고 new_project 로 넘어가야 한다.
    ["https://flow.google.com/?pli=1", "landing"],
    ["https://flow.google.com/about", "landing"],
    ["https://flow.google.com/project/xyz", "editor"],
    ["https://accounts.google.com/v3/signin/identifier?x=1", "login"],
    ["https://zum.com/", "other"]
  ];
  const bad = cases.filter(([u, want]) => classify(u) !== want);
  out(bad.length ? { ok: false, failed: bad.map(([u, w]) => `${u} → ${classify(u)} (기대: ${w})`) } : { ok: true, cases: cases.length });
  process.exit(0);
}

let browser;
try {
  const cfg = await selectors();
  browser = await connect();

  const result =
    cmd.action === "status"
      ? await status(browser, cfg)
      : cmd.action === "open_url"
        ? await openUrl(browser, cfg, cmd)
      : cmd.action === "new_project"
        ? await newProject(browser, cfg)
        : cmd.action === "harvest"
          ? await harvest(browser, cfg, cmd)
          : cmd.action === "set_guideline"
            ? await setGuideline(browser, cfg, cmd)
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