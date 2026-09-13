# mix run priv/repo/sync_prompts.exs
#
# priv/prompts/*.txt 를 prompt_templates 로 올린다. 파일이 원본이고 DB 는 사본이다 —
# 프롬프트는 텍스트 편집기로 고치는 게 편하고, 화면에서도 고칠 수 있게 DB 에도 둔다.
# 같은 내용이면 새 버전을 만들지 않는다.

import Ecto.Query

alias VideoTool.Repo
alias VideoTool.Presets.{PromptTemplate, StylePreset, DomainPreset}

dir = Path.join(:code.priv_dir(:video_tool), "prompts")

for stage <- ~w(clean info video) do
  path = Path.join(dir, "#{stage}.txt")

  if File.exists?(path) do
    body = File.read!(path)

    latest =
      Repo.one(
        from t in PromptTemplate,
          where: t.stage == ^stage,
          order_by: [desc: t.version],
          limit: 1
      )

    cond do
      latest && latest.body == body ->
        IO.puts("#{stage}: 그대로 (v#{latest.version})")

      true ->
        version = if latest, do: latest.version + 1, else: 1

        Repo.update_all(from(t in PromptTemplate, where: t.stage == ^stage), set: [is_active: false])

        {:ok, saved} =
          %PromptTemplate{}
          |> PromptTemplate.changeset(%{
            stage: stage,
            body: body,
            version: version,
            is_active: true,
            notes: "priv/prompts/#{stage}.txt 에서 동기화"
          })
          |> Repo.insert()

        IO.puts("#{stage}: v#{saved.version} 로 올림 (#{String.length(body)}자)")
    end
  end
end

# ── 그림체: 사용자가 실제로 쓰던 공통 기준 ──────────────────────

clean_rules = """
* {{project.aspect}} 영상 ({{project.orientation}})
* {{var.렌더링}}
* 선명하고 직관적인 구조
* 실제 구조와 원리를 이해하기 쉬운 시각화
* 입체감과 깊이감이 확실한 구성
* 영화처럼 역동적인 카메라 구도
* 장면마다 핵심 대상이 명확하게 보이도록 구성
* 과도하게 복잡한 배경은 피하고 설명 대상에 시선이 집중되도록 구성
* 동일한 대상이 여러 장면에 등장할 경우 디자인, 색상, 형태, 재질을 일관되게 유지
* 장면이 바뀌더라도 전체 영상의 3D 그래픽 스타일과 조명 품질을 통일
* 필요할 경우 단면도, 절개 구조, 분해된 구조, 확대 구조, 투시 구조 등을 활용
* 실제 사진처럼 평범하게 만들기보다 교육용 3D 다큐멘터리·공학 시각화 영상처럼 명확하고 인상적으로 표현
"""

variables = %{
  "렌더링" => "고품질 3D 렌더링",
  "영상성격" => "고품질 3D 인포그래픽 영상의 키프레임",
  "장면길이" => "3~4초정도로 구성되고 절대로 5초를 넘어가서는 안됩니다",
  "클립길이" => "8초",
  "빠른줌비율" => "약 3개 장면 중 1개 정도",
  "강조색" => "밝은 빨강, 전기 파랑, 시안, 노랑, 주황, 초록, 보라, 마젠타",
  "표기언어" => "한국어",
  # 글자 모양과 그래픽 효과는 화면(/prompts)에서 고르는 값이다.
  # Presets.variable_choices/0 에 선택지 문장이 있다 — 여기 기본값은 그중 하나여야
  # 화면에서 열었을 때 '직접 입력한 값' 으로 뜨지 않는다.
  "이미지글꼴" => "굵은 고딕체. 획 굵기가 일정하고 끝이 각져 있다. 제목용으로 크게 쓴다.",
  "글자스타일" =>
    "네온 사인처럼 발광하는 굵은 글자. 글자 자체가 빛을 내고 주변에 은은한 글로우가 번진다. 어두운 배경에서 가장 잘 보인다.",
  "그래픽효과" =>
    "발광, 네온 글로우, 밝은 외곽선, 반투명 컬러 면, 라이트 트레일, 스캔 효과, 에너지 라인, 깊이감 있는 그래픽 레이어를 적극적으로 사용하라.",
  "최종품질" =>
    "고품질 교육 다큐멘터리, 프리미엄 유튜브 인포그래픽 영상, 전문적인 건축·공학 설명 영상의 키프레임"
}

style =
  case Repo.get_by(StylePreset, slug: "infographic-3d") do
    nil -> %StylePreset{}
    row -> row
  end
  |> StylePreset.changeset(%{
    name: "3D 인포그래픽 다큐",
    slug: "infographic-3d",
    clean_rules: clean_rules,
    camera_rules:
      "자유 3D 카메라. 실제 깊이를 가진 공간 안에서 위치가 이동하는 느낌으로 연출한다. " <>
        "2D 확대·축소나 좌우 밀기로 대신하지 않는다.",
    global_style: "",
    asset_definitions: "",
    default_aspect: "16:9",
    variables: variables,
    is_active: true
  })
  |> Repo.insert_or_update!()

IO.puts("""

그림체 '#{style.name}' (#{style.slug}) 준비됨. 변수 #{map_size(style.variables)}개:
#{Enum.map_join(style.variables, "\n", fn {k, v} -> "  {{var.#{k}}} = #{String.slice(v, 0, 50)}" end)}

프로젝트를 이 그림체로 만들면 위 값들이 프롬프트에 꽂힌다.
값을 바꾸려면 화면(/prompts)이나 이 파일을 고치고 다시 돌리면 된다.
""")

_ = DomainPreset