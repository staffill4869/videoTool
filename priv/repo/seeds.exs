# mix run priv/repo/seeds.exs
#
# 프리셋 시드. 프롬프트 템플릿 본문은 자리표시자만 물려둔 뼈대다 —
# 실제로 쓰던 A4 2~4장짜리 프롬프트로 교체할 것. 교체는 body 만 갈아끼우면 된다.

alias VideoCRM.Repo
alias VideoCRM.Presets.{StylePreset, DomainPreset, Voice, PromptTemplate}
alias VideoCRM.Publishing.Channel

upsert = fn schema, key, attrs ->
  case Repo.get_by(schema, key) do
    nil -> struct(schema)
    row -> row
  end
  |> schema.changeset(attrs)
  |> Repo.insert_or_update!()
end

# ── 그림체 ──────────────────────────────────────────────────────

upsert.(StylePreset, [slug: "cinematic-3d-doc"], %{
  name: "시네마틱 3D 다큐",
  slug: "cinematic-3d-doc",
  global_style: """
  GLOBAL STYLE
  Photoreal 3D documentary render. Muted desaturated palette, volumetric haze,
  shallow depth of field. Natural key light with soft bounce. 35mm lens character.
  Consistent scale and materials across every shot.
  """,
  clean_rules: """
  모든 장면은 다음 기준을 지킨다.
  - 화면에 텍스트·숫자·화살표·라벨·아이콘·경로선을 넣지 않는다
  - 인물 얼굴은 클로즈업하지 않는다
  - 같은 대상은 모든 컷에서 같은 형태·색으로 유지한다
  """,
  camera_rules: """
  자유 3D 카메라. orbit · dolly · crane · 내부 진입 모두 허용.
  단 한 컷 안에서 카메라 동작은 하나만 쓴다. 3컷 중 1컷만 빠른 줌을 허용한다.
  """,
  asset_definitions: """
  공통 에셋: 지구본(무광 회청색), 컨테이너선(짙은 남색 선체·주황 컨테이너),
  지도 평면(옅은 회백색). 이 에셋들은 모든 컷에서 동일하게 재현한다.
  """,
  default_aspect: "16:9"
})

upsert.(StylePreset, [slug: "iso-lowpoly"], %{
  name: "아이소메트릭 로우폴리",
  slug: "iso-lowpoly",
  global_style: """
  GLOBAL STYLE
  Isometric low-poly diorama. Flat matte materials, no texture noise, crisp edges.
  Soft ambient occlusion, single warm key light at 45 degrees. Pastel-muted palette.
  Every scene is a self-contained diorama on a neutral base plate.
  """,
  clean_rules: """
  모든 장면은 다음 기준을 지킨다.
  - 화면에 텍스트·숫자·화살표·라벨·아이콘·경로선을 넣지 않는다
  - 등각 투영을 유지한다. 원근 왜곡을 넣지 않는다
  - 같은 대상은 모든 컷에서 같은 폴리 형태·색으로 유지한다
  """,
  camera_rules: """
  등각 유지. orbit · 내부 진입 · 카메라 롤 금지.
  허용 동작: 수평 트래킹, 수직 상승/하강, 등각을 유지한 줌인/줌아웃.
  ※ 그림체를 아이소메트릭으로 바꾸면 3D 다큐용 카메라 지시는 전부 무효다.
  """,
  asset_definitions: """
  공통 에셋: 지구본(로우폴리 12면), 컨테이너선(단색 블록), 지형 타일(6각 그리드).
  """,
  default_aspect: "16:9"
})

# ── 장르 ────────────────────────────────────────────────────────

upsert.(DomainPreset, [slug: "arch-eng"], %{
  name: "건축·공학",
  slug: "arch-eng",
  info_rules: """
  건축·공학 특화 기준
  - 치수는 항상 단위와 함께 쓴다. 허용 목록에 없는 치수는 넣지 않는다
  - 단면(절개도)에는 재료 해칭을 넣고 하중 방향을 화살표로 표시한다
  - 비교는 같은 축척으로 나란히 둔다. 축척이 다르면 축척 표시를 넣는다
  """,
  element_list: """
  사용 가능 요소: 치수선, 지시선, 단면 해칭, 하중 화살표, 범례, 축척 막대,
  단계 번호(원형 배지), 강조 외곽선
  """,
  color_semantics: %{"하중" => "빨강", "구조체" => "회색", "신설" => "파랑", "기존" => "연회색"},
  video_topic_rules: """
  주제별 자동 적용
  - 구조 설명: 단면 절개 후 내부 노출 → 하중 경로 순서대로 강조
  - 시공 순서: 단계 번호 순서대로 요소가 하나씩 등장
  """
})

upsert.(DomainPreset, [slug: "history-military"], %{
  name: "역사·군사",
  slug: "history-military",
  info_rules: """
  역사·군사 특화 기준
  - 세력은 색으로만 구분한다. 국기·문양을 쓰지 않는다
  - 이동 경로는 실선 화살표, 계획/미실행은 점선
  - 연도·지명·인명은 허용 목록에 있는 것만 쓴다
  """,
  element_list: """
  사용 가능 요소: 경로 화살표, 전선(front line), 부대 블록, 지명 라벨,
  연도 배지, 범례, 축척 막대, 강조 외곽선
  """,
  color_semantics: %{"청나라" => "빨강", "조선" => "파랑", "경로" => "주황", "중립" => "회색"},
  video_topic_rules: """
  주제별 자동 적용
  - 진격: 경로선이 시간 순으로 뻗어나가며 전선이 밀린다
  - 포위: 바깥에서 안쪽으로 화살표가 좁혀 들어간다
  """
})

# ── 보이스 ──────────────────────────────────────────────────────
# chars_per_sec 는 초기 추정치다. generate_narration 실측으로 갱신된다.

upsert.(Voice, [slug: "mark"], %{
  slug: "mark",
  provider: "higgsfield",
  variant: "elevenlabs",
  voice_id: "REPLACE_WITH_HIGGSFIELD_VOICE_ID",
  display_name: "Mark",
  lang: "ko",
  chars_per_sec: 5.9,
  sample_count: 0,
  is_default: true
})

# ── 프롬프트 템플릿 ─────────────────────────────────────────────

templates = [
  {"clean",
   """
   Generate {{scene_count}} separate images, aspect ratio {{project.aspect}}.

   {{style.global_style}}

   {{style.asset_definitions}}

   CLEAN 기준
   {{style.clean_rules}}

   ── 장면 목록 ──
   {{scenes}}
   """, "CLEAN(인포그래픽 없는 순수 장면). 실제 쓰던 프롬프트로 body 를 교체할 것"},
  {"info",
   """
   앞서 만든 {{scene_count}}장의 이미지에 한글 인포그래픽을 얹는다.
   화면비 {{project.aspect}}, 원본 장면은 그대로 두고 요소만 추가한다.

   {{style.global_style}}

   {{domain.info_rules}}

   사용 가능 요소
   {{domain.element_list}}

   색 규칙: {{domain.color_semantics}}

   {{allowed_facts}}

   ── 장면별 지시 ──
   {{scenes}}
   """, "INFO(한글 라벨·화살표·수치). allowed_facts 가 여기서만 주입된다"},
  {"video",
   """
   앞서 만든 이미지 쌍으로 8초 클립을 만든다.
   CLEAN 을 시작 프레임, INFO 를 종료 프레임으로 쓴다. 화면비 {{project.aspect}}.

   {{style.global_style}}

   카메라 규칙
   {{style.camera_rules}}

   {{domain.video_topic_rules}}

   ── 장면별 지시 ──
   {{scenes}}
   """, "영상. 그림체를 바꾸면 camera_rules 가 함께 바뀌어야 한다"},
  {"tts",
   """
   아래 대본을 한국어로 읽는다. 속도는 자연스러운 해설 속도.
   숫자는 한글로 읽고, 문장 끝에서 0.3초 쉰다.
   """, "TTS 지시문"}
]

for {stage, body, notes} <- templates do
  upsert.(PromptTemplate, [stage: stage, version: 1], %{
    stage: stage,
    body: body,
    version: 1,
    is_active: true,
    notes: notes
  })
end

# ── 발행 채널 ───────────────────────────────────────────────────
# 자격증명은 넣지 않는다. credential_ref 만 두고 실제 토큰은 OS 자격증명 저장소에 있다.

upsert.(Channel, [slug: "yt-main"], %{
  slug: "yt-main",
  platform: "youtube",
  display_name: "유튜브 메인 채널",
  credential_ref: "videoCRM/youtube/yt-main",
  aspect_required: "any",
  max_duration_sec: 0,
  default_privacy: "private",
  default_category: "27",
  title_pattern: "{title}",
  default_hashtags: ["지식", "인포그래픽"]
})

upsert.(Channel, [slug: "yt-shorts"], %{
  slug: "yt-shorts",
  platform: "youtube",
  display_name: "유튜브 쇼츠",
  credential_ref: "videoCRM/youtube/yt-main",
  aspect_required: "9:16",
  max_duration_sec: 180,
  default_privacy: "private",
  default_category: "27",
  title_pattern: "{title} #Shorts",
  default_hashtags: ["Shorts", "지식"]
})

upsert.(Channel, [slug: "ig-main"], %{
  slug: "ig-main",
  platform: "instagram",
  display_name: "인스타그램 릴스",
  credential_ref: "videoCRM/instagram/ig-main",
  aspect_required: "9:16",
  max_duration_sec: 900,
  default_privacy: "public",
  default_hashtags: ["릴스", "지식"]
})

if Mix.env() != :test do
  IO.puts("""
시드 완료
  그림체   #{Repo.aggregate(StylePreset, :count)}개
  장르     #{Repo.aggregate(DomainPreset, :count)}개
  보이스   #{Repo.aggregate(Voice, :count)}개
  템플릿   #{Repo.aggregate(PromptTemplate, :count)}개
  채널     #{Repo.aggregate(Channel, :count)}개

다음: 보이스의 voice_id 를 실제 힉스필드 값으로, 템플릿 body 를 실제 프롬프트로 교체할 것.
""")
end
