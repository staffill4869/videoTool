# videoCRM 서버 — 쓰는 법

서울 EC2에서 혼자 영상을 만듭니다. **이 노트북이 꺼져 있어도 돕니다.**

```
https://videotool.ceo-funds.com     ← 화면. 아무 PC·폰에서 열린다
ssh flow                            ← 서버. .pem 키가 있어야 한다
```

---

## 1. 평소에는 아무것도 안 합니다

타이머가 켜져 있으면 2시간마다 스스로 깨어나 한 편씩 만듭니다.
궁금할 때만 화면을 여세요.

| 보고 싶은 것 | 어디 |
|---|---|
| 지금 뭐 하는 중인지 | `/agent` |
| 편별 진행률 | `/projects` |
| 조회수·좋아요 | `/dashboard` |
| 프롬프트 고치기 | `/prompts` |
| API 키·토큰 | `/settings` |

---

## 2. 멈추기 / 켜기

### 화면에서 (키 없이)

`/agent` 오른쪽 위 버튼. 상황에 따라 바뀝니다.

- **무인 제작 끄기** — 타이머·루프·에이전트를 멈춥니다.
  돌던 Flow 생성과 합성은 **일부러 안 죽입니다** (이미 크레딧을 썼거나 거의 끝난 일).
- **한 번 돌리기** — 한 편 만들고 스스로 멈춥니다.

### 터미널에서 (키 필요)

```bash
ssh flow flow-stop            # 루프만 멈춤 (화면은 계속 열림)
ssh flow flow-stop all        # 앱·크롬까지 내림 (서버는 켜짐 = 과금 계속)

ssh flow flow-start           # 앱 올리기
ssh flow flow-start loop      # 지금 한 번 (발행까지)
ssh flow flow-start auto      # 2시간마다 자동  ← 화면에는 없는 유일한 것
```

**`auto` 만 화면에 안 둔 이유**: 켜두면 사람 없이 계속 크레딧이 나갑니다.
실수로 눌리면 안 되는 유일한 버튼이라 키 있는 사람만 켜게 했습니다.

---

## 3. 서버를 껐다 켤 때

**끄기** — AWS 콘솔 → EC2 → 인스턴스 → `인스턴스 중지`

> 터미널에서 `sudo shutdown` 은 **확인 전에 쓰지 마세요.**
> 인스턴스의 `종료 동작` 이 `Terminate` 면 서버가 **삭제**됩니다.
> 콘솔 → 작업 → 인스턴스 설정 → 종료 동작 변경에서 `중지` 인지 먼저 보세요.

**켜기** — 콘솔 → `인스턴스 시작`. 그 다음 **아무것도 안 해도 됩니다.**
systemd가 순서대로 올립니다:

```
postgresql → flow-xvfb → flow-chrome → videocrm → cloudflared
```

2분쯤 뒤:

```bash
ssh flow flow-check
```

전부 ✓ 면 끝입니다. 구글 로그인도 유지됩니다(프로필이 디스크에 있습니다).

### 꺼져 있을 때도 나가는 돈

| | |
|---|---|
| 컴퓨팅 | 0원 |
| 디스크 50GB | 월 6천원쯤 |
| 공인 IPv4 | 월 5천원쯤 |

완전히 0원으로 만들려면 **종료(Terminate)** 인데, 그러면 전부 다시 깔아야 합니다.

---

## 4. 뭔가 안 될 때

### 먼저 이것부터

```bash
ssh flow flow-check
```

```
── 서비스 ──         postgresql · flow-xvfb · flow-chrome · videocrm
── 연결 ──           크롬 CDP 9222 · 앱→크롬 · Flow 탭
── 자원 ──           메모리·디스크 여유
```

### 증상별

| 증상 | 원인과 처방 |
|---|---|
| **화면이 안 열림** | Access 로그인부터 뜨는지 확인. `530` 이면 터널이 꺼진 것 → `ssh flow "sudo systemctl start cloudflared"` |
| **화면은 뜨는데 클릭이 안 먹음** | `/assets/js/app.js` 가 404인지 보세요. esbuild 실패입니다 |
| **"Flow 탭이 없습니다"** | 크롬이 죽었거나 로그인이 풀림 → `ssh flow flow-watch` 로 확인, 필요하면 아래 noVNC |
| **루프가 도는데 아무것도 안 만듦** | 토큰 만료. `/settings` 의 **Claude 에이전트 토큰** 을 새로 넣으세요 |
| **영상이 나레이션보다 짧음** | 클립이 다 차기 전에 나레이션을 만든 것. 나레이션만 다시 만들면 됩니다 |

### 서버 크롬 화면을 직접 봐야 할 때

구글이 재인증을 요구하거나 Flow UI가 바뀌었을 때만 씁니다. 평소엔 꺼둡니다.

```bash
ssh flow "~/bin/flow-vnc.sh start"
ssh -L 6080:127.0.0.1:6080 flow        # 이 창은 켜둔 채로
```
→ 브라우저에서 `http://127.0.0.1:6080/vnc.html`

끝나면:
```bash
ssh flow "~/bin/flow-vnc.sh stop"
```

---

## 5. 다른 PC에서 쓰려면

**화면만 볼 사람** — 아무것도 안 깔아도 됩니다.
`https://videotool.ceo-funds.com` 열고, 등록된 이메일로 오는 코드를 넣으면 끝.
이메일 추가는 Cloudflare Zero Trust → Access → Applications → videotool → 정책.

**서버를 만질 사람** — `.pem` 키가 필요합니다.

```powershell
# 1) 키 복사 후 권한 잠그기 (안 하면 OpenSSH 가 거부합니다)
icacls "키경로\stafill.pem" /inheritance:r
icacls "키경로\stafill.pem" /grant:r "$($env:USERNAME):(R)"
```

```
# 2) C:\Users\<사용자>\.ssh\config
Host flow
    HostName 16.184.47.219
    User ec2-user
    IdentityFile C:/경로/stafill.pem
    IdentitiesOnly yes
    ServerAliveInterval 60
```

> `.ssh/config` 를 편집기로 다시 저장하면 권한이 풀려 `Bad owner or permissions` 가 납니다.
> 그때마다 `icacls ... /inheritance:r` 을 다시 거세요.

**보안 그룹의 SSH가 `내 IP` 로 돼 있으면 다른 네트워크에서는 막힙니다.**
콘솔에서 그 IP를 추가해야 합니다.

---

## 6. 프롬프트 고치기

`/prompts` 한 군데서 다 합니다.

| 탭 | 무엇 |
|---|---|
| `clean` | 배경 이미지 |
| `info` | 그 위에 얹는 수치·지시선 |
| `video` | 8초 클립 |
| `agent` | **무인 루프가 에이전트에게 주는 작업 절차** |

저장하면 새 버전이 되고 **다음 라운드부터** 먹습니다. 옛 버전은 남습니다.

`agent` 탭을 비우거나 너무 짧게 저장하면 루프가 **파일에 박아둔 기본값**으로
떨어집니다 — 실수로 지워도 멈추지 않습니다.

옛 실험 프로젝트(27·61~68) 몇 개는 **자기만의 프롬프트**를 갖고 있어서
`/prompts` 를 고쳐도 안 바뀝니다. 그 편의 `/projects/:id` 에서 따로 고치세요.

---

## 7. 구조

```
[아무 PC·폰]  https://videotool.ceo-funds.com
                   │  Cloudflare Access (이메일 확인)
                   ▼
        ┌──── AWS EC2 (서울) ────────────────────────┐
        │  cloudflared ──▶ Phoenix :4300             │
        │                      │                     │
        │                      │ node driver.mjs     │
        │                      ▼ CDP :9222           │
        │            Chrome (로그인됨) ── Xvfb :98   │
        │                      ▲                     │
        │            크레딧은 여기서 깎인다          │
        │                                            │
        │  PostgreSQL · ffmpeg · tesseract · Node    │
        │  claude (에이전트) ← 2시간마다 systemd     │
        └────────────────────────────────────────────┘
```

**Flow 에는 API 가 없습니다.** 크레딧은 `flow.google.com` 화면 안에서만 깎이므로,
사람 대신 크롬을 조종해야 합니다. 크롬은 화면이 있어야 도니까 `Xvfb` 로 가짜
모니터를 만들어 거기 띄웠습니다. `--headless` 는 안 됩니다 — 구글 로그인이 튕깁니다.

---

## 8. 열려 있는 포트

**22번(SSH)뿐입니다.** 나머지는 전부 `127.0.0.1` 에만 묶여 있습니다.

```
4300  앱          ← 터널로만
9222  크롬 디버그 ← 열리면 로그인된 구글 세션이 통째로 털립니다. 절대 열지 마세요
5900  VNC         ← 필요할 때만, SSH 터널로만
6080  noVNC       ← 위와 같음
```

터널은 **바깥으로 나가는** 연결이라 인바운드 포트가 필요 없습니다.
