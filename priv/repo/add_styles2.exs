# 그림체 2차 추가. 고를 게 없다는 게 계속 문제였다.
alias VideoTool.Repo
alias VideoTool.Presets
alias VideoTool.Presets.StylePreset

{:ok, ref} = Presets.fetch_style("infographic-3d")
base = ref.variables || %{}

put = fn attrs ->
  row = Repo.get_by(StylePreset, slug: attrs.slug) || %StylePreset{}
  {:ok, s} = row |> StylePreset.changeset(attrs) |> Repo.insert_or_update()
  IO.puts("  #{s.slug}  #{s.name}")
end

put.(%{
  name: "웹툰 셀 애니",
  slug: "webtoon-cel",
  global_style: """
  GLOBAL STYLE
  Korean webtoon / cel animation look. Clean bold outlines, flat cel shading with
  two tones per surface, no gradients inside shapes. Saturated but harmonious palette.
  Simple painted backgrounds with soft bokeh. Characters read clearly at phone size.
  """,
  clean_rules: """
  모든 장면은 다음 기준을 지킨다.
  - 화면에 텍스트·숫자·화살표·라벨·아이콘·경로선을 넣지 않는다
  - 외곽선은 굵고 일정하게. 명암은 두 단계만 쓴다
  - 같은 인물은 모든 컷에서 같은 머리 모양·옷·색으로 유지한다
  - 말풍선과 효과음 문자를 넣지 않는다
  """,
  camera_rules: """
  만화 컷 전환처럼 시점을 바꾼다. 넓은 컷 → 중간 컷 → 클로즈업.
  카메라가 3D 공간을 자유롭게 도는 대신, 정해진 각도 사이를 옮겨 간다.
  한 컷 안에서는 완만한 밀기나 당기기만 쓴다.
  """,
  asset_definitions: """
  공통 에셋: 인물(같은 얼굴형·머리·의상), 배경 건물(단순화된 면 분할).
  모든 컷에서 같은 선 굵기와 같은 채도로 재현한다.
  """,
  default_aspect: "16:9",
  variables: Map.merge(base, %{
    "렌더링" => "셀 애니메이션",
    "영상성격" => "웹툰 셀 애니메이션의 키프레임",
    "글자스타일" => "장식 없는 굵은 산세리프. 발광이나 그림자 없이 단색으로 또렷하게. 필요하면 얇은 외곽선만 넣어 배경과 분리한다.",
    "그래픽효과" => "발광과 그림자를 쓰지 않는다. 단색 면, 또렷한 선, 단순한 도형만으로 구성하라. 색은 적게 쓰고 대비로 구분하라."
  })
})

put.(%{
  name: "클레이 스톱모션",
  slug: "claymation",
  global_style: """
  GLOBAL STYLE
  Stop-motion clay animation. Every object is modelling clay with visible fingerprints,
  tool marks and slight asymmetry. Matte surfaces, no specular highlights.
  Practical tabletop lighting with soft shadows. Warm homely palette.
  """,
  clean_rules: """
  모든 장면은 다음 기준을 지킨다.
  - 화면에 텍스트·숫자·화살표·라벨·아이콘·경로선을 넣지 않는다
  - 모든 사물에 손자국과 도구 자국이 보여야 한다. 매끈하게 만들지 않는다
  - 좌우 완전 대칭을 피한다. 손으로 빚은 불균형을 남긴다
  - 광택을 넣지 않는다
  """,
  camera_rules: """
  탁자 위 세트를 찍는 카메라. 느리고 짧은 이동만 쓴다.
  급격한 회전이나 비행을 쓰지 않는다 — 스톱모션에서는 불가능한 움직임이라 인상이 깨진다.
  """,
  asset_definitions: """
  공통 에셋: 클레이 인물(같은 색 배합·같은 크기), 클레이 소품.
  모든 컷에서 같은 점토 질감과 같은 조명 방향으로 재현한다.
  """,
  default_aspect: "16:9",
  variables: Map.merge(base, %{
    "렌더링" => "클레이 스톱모션",
    "영상성격" => "스톱모션 애니메이션의 키프레임",
    "글자스타일" => "펜으로 쓴 듯한 손글씨. 살짝 기울고 굵기가 일정하지 않다. 밑줄이나 동그라미도 손으로 그은 느낌으로.",
    "그래픽효과" => "발광과 그림자를 쓰지 않는다. 단색 면, 또렷한 선, 단순한 도형만으로 구성하라. 색은 적게 쓰고 대비로 구분하라."
  })
})

put.(%{
  name: "블루프린트 도면",
  slug: "blueprint",
  global_style: """
  GLOBAL STYLE
  Technical blueprint drawing. Deep blue ground with white or cyan line work.
  Orthographic and isometric projections, dimension lines, hatching, grid.
  No photographic texture. Everything reads as a drafted engineering document.
  """,
  clean_rules: """
  모든 장면은 다음 기준을 지킨다.
  - 화면에 텍스트·숫자·화살표·라벨을 넣지 않는다 (선과 해칭은 허용)
  - 모든 형태는 선으로만 표현한다. 면을 채우지 않는다
  - 원근을 쓰더라도 소실점 하나로 제한한다
  - 색은 배경 남색과 선 흰색·시안 세 가지만 쓴다
  """,
  camera_rules: """
  도면을 들여다보는 시점. 평행 이동과 확대만 쓴다.
  단면을 보여줄 때는 카메라를 돌리지 않고 도면 자체가 펼쳐지거나 겹쳐지게 한다.
  """,
  asset_definitions: """
  공통 에셋: 격자 배경(일정 간격), 치수선(양끝 화살표), 해칭(45도).
  모든 컷에서 같은 선 굵기 체계를 쓴다 — 외형선 굵게, 숨은선 점선, 중심선 일점쇄선.
  """,
  default_aspect: "16:9",
  variables: Map.merge(base, %{
    "렌더링" => "제도 도면",
    "영상성격" => "기술 도면의 키프레임",
    "글자스타일" => "인쇄물처럼 평평하고 차분한 글자. 발광 없음. 교과서 도해에 가까운 절제된 표기.",
    "그래픽효과" => "제도 도면처럼 가는 실선, 치수선, 지시선, 해칭으로 표현하라. 발광 대신 선 굵기와 점선·실선 구분으로 위계를 만들어라.",
    "강조색" => "시안, 흰색, 주황"
  })
})

put.(%{
  name: "미니어처 틸트시프트",
  slug: "tilt-shift-mini",
  global_style: """
  GLOBAL STYLE
  Real-world scene shot to look like a miniature model. Extreme tilt-shift blur at top
  and bottom, razor-sharp narrow band in the middle. Boosted saturation and contrast.
  High angle looking down. Tiny figures, toy-like vehicles.
  """,
  clean_rules: """
  모든 장면은 다음 기준을 지킨다.
  - 화면에 텍스트·숫자·화살표·라벨·아이콘·경로선을 넣지 않는다
  - 항상 높은 곳에서 내려다본다. 눈높이 구도를 쓰지 않는다
  - 초점이 맞는 띠는 화면의 3분의 1을 넘지 않는다
  - 인물은 작고 얼굴이 보이지 않는 크기로 둔다
  """,
  camera_rules: """
  부감 고정에 가깝다. 느린 수평 이동과 완만한 하강만 쓴다.
  지면에 가까이 내려가지 않는다 — 내려가면 미니어처라는 착시가 깨진다.
  """,
  asset_definitions: """
  공통 에셋: 차량(장난감처럼 단순화), 인물(2~3픽셀 크기 실루엣), 건물.
  모든 컷에서 같은 축척과 같은 흐림 강도로 재현한다.
  """,
  default_aspect: "16:9",
  variables: Map.merge(base, %{
    "렌더링" => "틸트시프트 실사",
    "영상성격" => "미니어처처럼 보이는 실사 촬영본의 키프레임",
    "글자스타일" => "뉴스·다큐 자막처럼 반투명 띠 위에 올린 단정한 글자. 띠는 배경을 가리지 않을 정도로만 어둡게.",
    "그래픽효과" => "방송 인포그래픽처럼 반투명 패널, 부드러운 그림자, 절제된 강조색을 쓰라. 과한 발광은 피하고 정보 위계를 또렷하게 하라."
  })
})

put.(%{
  name: "빈티지 콜라주",
  slug: "vintage-collage",
  global_style: """
  GLOBAL STYLE
  Mixed-media editorial collage. Cut-out halftone photographs on textured paper,
  visible scissor edges and paper shadows. Limited risograph palette with
  slight misregistration. Xerox grain over everything.
  """,
  clean_rules: """
  모든 장면은 다음 기준을 지킨다.
  - 화면에 텍스트·숫자·화살표·라벨·아이콘·경로선을 넣지 않는다
  - 오려낸 가장자리를 매끈하게 다듬지 않는다. 가위 자국을 남긴다
  - 인쇄 망점과 복사기 잡티가 항상 보이게 한다
  - 인물 얼굴은 흑백 하프톤으로만 처리한다
  """,
  camera_rules: """
  종이 위를 움직이는 시점. 요소들이 서로 다른 속도로 밀리는 시차를 쓴다.
  3D 회전이나 내부 진입을 쓰지 않는다 — 오려 붙인 종이에는 안쪽이 없다.
  """,
  asset_definitions: """
  공통 에셋: 하프톤 인물 컷아웃, 종이 바닥(결·얼룩), 리소 인쇄 색면(2~3색).
  모든 컷에서 같은 망점 크기와 같은 어긋남 정도로 재현한다.
  """,
  default_aspect: "16:9",
  variables: Map.merge(base, %{
    "렌더링" => "믹스드미디어 콜라주",
    "영상성격" => "에디토리얼 콜라주의 키프레임",
    "글자스타일" => "인쇄물처럼 평평하고 차분한 글자. 발광 없음. 교과서 도해에 가까운 절제된 표기.",
    "그래픽효과" => "발광과 그림자를 쓰지 않는다. 단색 면, 또렷한 선, 단순한 도형만으로 구성하라. 색은 적게 쓰고 대비로 구분하라.",
    "강조색" => "리소 형광 주황, 남색, 바랜 분홍"
  })
})

put.(%{
  name: "픽셀 도트",
  slug: "pixel-art",
  global_style: """
  GLOBAL STYLE
  Pixel art. Strict low-resolution grid, hard pixel edges, no anti-aliasing.
  Limited palette of 16 to 24 colours with deliberate dithering for gradients.
  Side-on or 3/4 top-down view. Chunky readable silhouettes.
  """,
  clean_rules: """
  모든 장면은 다음 기준을 지킨다.
  - 화면에 텍스트·숫자·화살표·라벨·아이콘·경로선을 넣지 않는다
  - 픽셀 격자를 흐리지 않는다. 부드러운 경계를 만들지 않는다
  - 색은 24색을 넘기지 않는다. 그라데이션은 디더링으로만 표현한다
  - 픽셀 크기를 컷마다 바꾸지 않는다
  """,
  camera_rules: """
  픽셀 격자에 맞춰 정수 단위로만 이동한다. 회전이나 비정수 확대를 쓰지 않는다 —
  격자가 흐려지면 픽셀아트가 아니게 된다.
  """,
  asset_definitions: """
  공통 에셋: 인물 스프라이트(같은 높이·같은 팔레트), 타일 배경.
  모든 컷에서 같은 픽셀 크기와 같은 24색 팔레트를 쓴다.
  """,
  default_aspect: "16:9",
  variables: Map.merge(base, %{
    "렌더링" => "픽셀 도트",
    "영상성격" => "픽셀아트 장면의 키프레임",
    "글자스타일" => "장식 없는 굵은 산세리프. 발광이나 그림자 없이 단색으로 또렷하게. 필요하면 얇은 외곽선만 넣어 배경과 분리한다.",
    "그래픽효과" => "발광과 그림자를 쓰지 않는다. 단색 면, 또렷한 선, 단순한 도형만으로 구성하라. 색은 적게 쓰고 대비로 구분하라."
  })
})

IO.puts("\n그림체 #{Repo.aggregate(StylePreset, :count)}개")
