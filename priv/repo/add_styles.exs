# 그림체를 늘린다.
#
# 씨앗에 3개뿐이라 고를 게 없었다. 아래는 지식 설명 채널에서 실제로 쓰는 화풍들이다.
# 변수는 기존 그림체 것을 물려받되 화풍마다 다른 값만 덮어쓴다 —
# 프롬프트가 {{var.*}} 로 참조하므로 키가 빠지면 ⟨미설정⟩ 으로 렌더된다.

alias VideoTool.Repo
alias VideoTool.Presets
alias VideoTool.Presets.StylePreset

{:ok, ref} = Presets.fetch_style("infographic-3d")
base_vars = ref.variables || %{}

upsert = fn attrs ->
  row = Repo.get_by(StylePreset, slug: attrs.slug) || %StylePreset{}
  {:ok, s} = row |> StylePreset.changeset(attrs) |> Repo.insert_or_update()
  IO.puts("  #{s.slug}  #{s.name}")
end

upsert.(%{
  name: "2D 플랫 모션그래픽",
  slug: "flat-2d-motion",
  global_style: """
  GLOBAL STYLE
  Flat 2D editorial motion graphics. No 3D perspective, no gradients on shapes.
  Solid fills, thick uniform strokes, generous negative space.
  Limited palette: two brand colors plus neutral gray and off-white paper ground.
  Everything reads as cut paper on a flat plane.
  """,
  clean_rules: """
  모든 장면은 다음 기준을 지킨다.
  - 화면에 텍스트·숫자·화살표·라벨·아이콘·경로선을 넣지 않는다
  - 원근과 그림자를 쓰지 않는다. 모든 요소는 같은 평면 위에 있다
  - 도형은 단색으로 채운다. 그라데이션·질감·발광을 넣지 않는다
  - 인물은 얼굴 이목구비 없이 실루엣으로만 그린다
  """,
  camera_rules: """
  카메라는 평면 위를 움직인다. 좌우 이동 · 확대 축소 · 요소 단위 등장과 퇴장만 쓴다.
  3D orbit 이나 내부 진입을 쓰지 않는다 — 이 화풍에는 안쪽이라는 게 없다.
  전환은 도형이 자라거나 밀려나며 일어난다. 페이드로 때우지 않는다.
  """,
  asset_definitions: """
  공통 에셋: 인물 실루엣(단색, 이목구비 없음), 건물 블록(직사각형 조합),
  화살표(끝이 뭉툭한 굵은 선). 모든 컷에서 같은 굵기와 모서리 처리로 재현한다.
  """,
  default_aspect: "16:9",
  variables:
    Map.merge(base_vars, %{
      "렌더링" => "플랫 2D 벡터",
      "영상성격" => "플랫 에디토리얼 모션그래픽의 키프레임",
      "글자스타일" =>
        "장식 없는 굵은 산세리프. 발광이나 그림자 없이 단색으로 또렷하게. 필요하면 얇은 외곽선만 넣어 배경과 분리한다.",
      "그래픽효과" =>
        "발광과 그림자를 쓰지 않는다. 단색 면, 또렷한 선, 단순한 도형만으로 구성하라. 색은 적게 쓰고 대비로 구분하라."
    })
})

upsert.(%{
  name: "종이 디오라마",
  slug: "paper-diorama",
  global_style: """
  GLOBAL STYLE
  Miniature paper-craft diorama shot on a tabletop. Every object is folded or cut
  paper with visible fiber, fold creases and slight warping. Warm tungsten key light
  from one side casting soft real shadows. Sepia-leaning palette, aged newsprint ground.
  Shallow depth of field as if shot with a macro lens.
  """,
  clean_rules: """
  모든 장면은 다음 기준을 지킨다.
  - 화면에 텍스트·숫자·화살표·라벨·아이콘·경로선을 넣지 않는다
  - 모든 사물은 종이로 만들어진 것처럼 보여야 한다. 금속·유리 질감을 쓰지 않는다
  - 조명은 한 방향에서만 온다. 그림자가 서로 어긋나지 않게 한다
  - 인물은 종이 인형으로, 얼굴은 단순한 실루엣으로 처리한다
  """,
  camera_rules: """
  탁자 위 미니어처를 들여다보는 카메라. 낮은 각도 접근 · 천천히 상승하는 부감 ·
  종이 구조물 사이를 통과하는 이동을 쓴다.
  피사계 심도를 얕게 유지해 미니어처라는 인상을 깨지 않는다.
  """,
  asset_definitions: """
  공통 에셋: 종이 인물(2mm 두께 실루엣), 종이 건물(접힌 모서리 보임),
  신문지 바닥면(누런 인쇄 질감). 모든 컷에서 같은 종이 두께와 결로 재현한다.
  """,
  default_aspect: "16:9",
  variables:
    Map.merge(base_vars, %{
      "렌더링" => "종이 공예 미니어처 실사 촬영",
      "영상성격" => "시네마틱 종이 디오라마 다큐의 키프레임",
      "글자스타일" =>
        "인쇄물처럼 평평하고 차분한 글자. 발광 없음. 교과서 도해에 가까운 절제된 표기.",
      "그래픽효과" =>
        "제도 도면처럼 가는 실선, 치수선, 지시선, 해칭으로 표현하라. 발광 대신 선 굵기와 점선·실선 구분으로 위계를 만들어라.",
      "강조색" => "바랜 빨강, 잉크 남색, 겨자색"
    })
})

upsert.(%{
  name: "실사 다큐",
  slug: "photoreal-doc",
  global_style: """
  GLOBAL STYLE
  Photorealistic documentary cinematography. Natural light only. Real materials,
  real wear and dirt. Muted palette, no color grading tricks. 35mm to 50mm lens.
  Composition leaves room for later graphic overlays.
  """,
  clean_rules: """
  모든 장면은 다음 기준을 지킨다.
  - 화면에 텍스트·숫자·화살표·라벨·아이콘·경로선을 넣지 않는다
  - 실제로 존재할 수 있는 장면만 만든다. 과장된 스케일이나 불가능한 구도를 쓰지 않는다
  - 인물 얼굴을 클로즈업하지 않는다. 실존 인물로 오인될 수 있다
  - 화면 한쪽은 비워 둔다. 나중에 그래픽이 올라간다
  """,
  camera_rules: """
  손에 든 카메라의 미세한 흔들림을 유지한다. 삼각대처럼 완벽하게 고정하지 않는다.
  한 컷에 카메라 동작 하나. 빠른 줌은 쓰지 않는다 — 이 화풍에서는 연출이 튄다.
  """,
  asset_definitions: """
  공통 에셋 없음. 장면마다 실제 장소와 사물을 그린다.
  다만 같은 대상이 여러 컷에 나오면 같은 계절·시간대·날씨로 유지한다.
  """,
  default_aspect: "16:9",
  variables:
    Map.merge(base_vars, %{
      "렌더링" => "실사 촬영",
      "영상성격" => "다큐멘터리 실사 촬영본의 키프레임",
      "글자스타일" =>
        "뉴스·다큐 자막처럼 반투명 띠 위에 올린 단정한 글자. 띠는 배경을 가리지 않을 정도로만 어둡게.",
      "그래픽효과" =>
        "방송 인포그래픽처럼 반투명 패널, 부드러운 그림자, 절제된 강조색을 쓰라. 과한 발광은 피하고 정보 위계를 또렷하게 하라."
    })
})

upsert.(%{
  name: "손그림 노트",
  slug: "sketch-notebook",
  global_style: """
  GLOBAL STYLE
  Hand-drawn notebook illustration. Ink pen on off-white paper with visible tooth.
  Loose confident linework, slightly uneven stroke weight, small overshoots at corners.
  Sparse watercolor washes that do not stay inside the lines.
  No perfect circles, no ruler-straight lines.
  """,
  clean_rules: """
  모든 장면은 다음 기준을 지킨다.
  - 화면에 텍스트·숫자·화살표·라벨·아이콘·경로선을 넣지 않는다
  - 선은 자를 댄 듯 반듯하면 안 된다. 손으로 그은 흔들림을 남긴다
  - 채색은 선 밖으로 조금 삐져나가게 한다
  - 종이 질감이 항상 보이게 한다
  """,
  camera_rules: """
  공책을 들여다보는 시점. 평면 위에서 이동하고 확대한다.
  3D 회전을 쓰지 않는다 — 그림이 종이에 그려진 것이라는 전제가 깨진다.
  요소는 그려지는 순서대로 나타난다. 한 번에 다 보여주지 않는다.
  """,
  asset_definitions: """
  공통 에셋: 펜선(0.5mm 균일하지 않은 굵기), 수채 워시(2~3색),
  종이 바닥(미색, 결 보임). 모든 컷에서 같은 펜과 같은 종이로 그린 것처럼 유지한다.
  """,
  default_aspect: "16:9",
  variables:
    Map.merge(base_vars, %{
      "렌더링" => "손그림 펜선 + 수채",
      "영상성격" => "공책에 그린 설명 그림의 키프레임",
      "글자스타일" =>
        "펜으로 쓴 듯한 손글씨. 살짝 기울고 굵기가 일정하지 않다. 밑줄이나 동그라미도 손으로 그은 느낌으로.",
      "그래픽효과" =>
        "발광과 그림자를 쓰지 않는다. 단색 면, 또렷한 선, 단순한 도형만으로 구성하라. 색은 적게 쓰고 대비로 구분하라.",
      "강조색" => "잉크 파랑, 주홍, 겨자색"
    })
})

IO.puts("\n그림체 #{Repo.aggregate(StylePreset, :count)}개")
