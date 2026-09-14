defmodule VideoTool.Presets.StylePreset do
  @moduledoc "그림체. 프로젝트끼리 공유하고 갈아끼우는 대상."
  use Ecto.Schema
  import Ecto.Changeset

  schema "style_presets" do
    field :name, :string
    field :slug, :string
    field :global_style, :string, default: ""
    field :clean_rules, :string, default: ""
    # 그림체를 바꾸면 영상 단계의 카메라 지시가 통째로 무효가 되므로 한 몸으로 둔다.
    field :camera_rules, :string, default: ""
    field :asset_definitions, :string, default: ""
    field :default_aspect, :string, default: "16:9"
    # 프롬프트의 {{var.이름}} 에 들어갈 값들. %{"렌더링" => "고품질 3D 렌더링", ...}
    field :variables, :map, default: %{}
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @fields ~w(name slug global_style clean_rules camera_rules asset_definitions
             default_aspect variables is_active)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:name, :slug])
    |> validate_inclusion(:default_aspect, ["16:9", "9:16"])
    |> unique_constraint(:slug)
  end
end

defmodule VideoTool.Presets.DomainPreset do
  @moduledoc "장르. 인포그래픽 규칙과 색 의미를 담는다."
  use Ecto.Schema
  import Ecto.Changeset

  schema "domain_presets" do
    field :name, :string
    field :slug, :string
    field :info_rules, :string, default: ""
    field :element_list, :string, default: ""
    # %{"청나라" => "빨강", "조선" => "파랑"}
    field :color_semantics, :map, default: %{}
    field :video_topic_rules, :string, default: ""
    field :variables, :map, default: %{}
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @fields ~w(name slug info_rules element_list color_semantics video_topic_rules variables is_active)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:name, :slug])
    |> unique_constraint(:slug)
  end
end

defmodule VideoTool.Presets.Voice do
  @moduledoc """
  TTS 보이스. `chars_per_sec` 는 실측으로 갱신된다 — 대본 길이를 미리 계산하기 위한 값이다.
  (60초로 쓴 대본이 130초로 나오는 일이 두 번 있었다.)
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "voices" do
    field :provider, :string, default: "higgsfield"
    field :voice_id, :string
    field :variant, :string, default: "elevenlabs"
    field :display_name, :string
    field :slug, :string
    field :lang, :string, default: "ko"
    field :chars_per_sec, :float, default: 5.9
    field :sample_count, :integer, default: 0
    field :is_default, :boolean, default: false
    field :preview_url, :string, default: ""
    field :gender, :string, default: ""
    # 낭독 속도. 0 이 보통이다. 길이가 안 맞는다고 여기를 올리지 않는다 —
    # 빨리 읽히면 설명 영상이 아니라 광고처럼 들린다. 안 맞으면 대본을 고친다.
    field :speech_rate, :float, default: 0.0

    timestamps(type: :utc_datetime)
  end

  @fields ~w(provider voice_id variant display_name slug lang chars_per_sec
             sample_count is_default preview_url gender speech_rate)a

  # 속도를 넉넉히 열어두면 결국 길이 맞추는 데 쓰게 된다. 좁게 막아둔다.
  @rate_min -0.2
  @rate_max 0.1

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:voice_id, :display_name, :slug])
    |> validate_number(:chars_per_sec, greater_than: 0)
    |> validate_number(:speech_rate,
      greater_than_or_equal_to: @rate_min,
      less_than_or_equal_to: @rate_max,
      message: "낭독 속도는 #{@rate_min}~#{@rate_max} 안에서만 조절합니다. 길이가 안 맞으면 대본을 고치세요"
    )
    |> unique_constraint(:slug)
  end
end

defmodule VideoTool.Presets.PromptTemplate do
  @moduledoc "단계별 프롬프트 뼈대. 자리표시자는 VideoTool.Prompt 참조."
  use Ecto.Schema
  import Ecto.Changeset

  @stages ~w(clean info video tts)

  schema "prompt_templates" do
    field :stage, :string
    field :body, :string, default: ""
    field :version, :integer, default: 1
    field :is_active, :boolean, default: true
    field :notes, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  def stages, do: @stages

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(stage body version is_active notes)a)
    |> validate_required([:stage, :body])
    |> validate_inclusion(:stage, @stages)
    |> unique_constraint([:stage, :version])
  end
end

defmodule VideoTool.Presets do
  @moduledoc "프리셋 조회. 프로젝트 생성 시 slug 로 참조한다."

  import Ecto.Query
  alias VideoTool.Repo
  alias VideoTool.Presets.{StylePreset, DomainPreset, Voice, PromptTemplate}

  def list_styles, do: Repo.all(from s in StylePreset, where: s.is_active, order_by: s.name)
  def list_domains, do: Repo.all(from d in DomainPreset, where: d.is_active, order_by: d.name)
  def list_voices, do: Repo.all(from v in Voice, order_by: v.display_name)

  def list_templates,
    do: Repo.all(from t in PromptTemplate, where: t.is_active, order_by: [t.stage, t.version])

  def fetch_style(slug), do: fetch_by_slug(StylePreset, slug, "그림체")
  def fetch_domain(slug), do: fetch_by_slug(DomainPreset, slug, "장르")
  def fetch_voice(slug), do: fetch_by_slug(Voice, slug, "보이스")

  @doc """
  기본 목소리를 정한다. 기본은 하나뿐이므로 나머지는 내린다.
  """
  def set_default_voice(%Voice{} = voice) do
    Repo.transaction(fn ->
      Repo.update_all(from(v in Voice, where: v.is_default), set: [is_default: false])
      Repo.update_all(from(v in Voice, where: v.id == ^voice.id), set: [is_default: true])
    end)
  end

  defp fetch_by_slug(schema, slug, label) do
    case Repo.get_by(schema, slug: slug) do
      nil -> {:error, "#{label} 프리셋 '#{slug}' 을(를) 찾을 수 없습니다"}
      row -> {:ok, row}
    end
  end

  @doc "해당 stage 의 활성 템플릿 중 가장 높은 버전."
  def fetch_template(stage) do
    query =
      from t in PromptTemplate,
        where: t.stage == ^stage and t.is_active,
        order_by: [desc: t.version],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, "'#{stage}' 단계의 활성 프롬프트 템플릿이 없습니다"}
      t -> {:ok, t}
    end
  end

  @doc """
  프롬프트 본문을 새 버전으로 저장한다. 덮어쓰지 않는 이유는 되돌릴 수 있어야 해서다 —
  프롬프트를 고치면 결과가 통째로 바뀌는데, 어떤 판이 좋았는지는 나중에야 안다.
  """
  def save_template(stage, body, notes \\ "화면에서 수정") do
    latest =
      Repo.one(from t in PromptTemplate, where: t.stage == ^stage, order_by: [desc: t.version], limit: 1)

    if latest && latest.body == body do
      {:ok, latest}
    else
      version = if latest, do: latest.version + 1, else: 1
      Repo.update_all(from(t in PromptTemplate, where: t.stage == ^stage), set: [is_active: false])

      %PromptTemplate{}
      |> PromptTemplate.changeset(%{
        stage: stage,
        body: body,
        version: version,
        is_active: true,
        notes: notes
      })
      |> Repo.insert()
    end
  end

  def template_versions(stage) do
    Repo.all(from t in PromptTemplate, where: t.stage == ^stage, order_by: [desc: t.version])
  end

  def activate_template(%PromptTemplate{} = template) do
    Repo.update_all(
      from(t in PromptTemplate, where: t.stage == ^template.stage),
      set: [is_active: false]
    )

    template |> PromptTemplate.changeset(%{is_active: true}) |> Repo.update()
  end

  @doc """
  고르기 쉬운 변수의 선택지.

  변수 값은 프롬프트에 그대로 꽂히는 문장이라 손으로 쓰기 어렵다.
  자주 바꾸는 것만 문장을 미리 써 두고 화면에서 고르게 한다.
  여기 없는 변수는 자유 입력으로 남는다 — 목록에 없다고 못 쓰는 게 아니다.
  """
  def variable_choices do
    %{
      "글자스타일" => [
        {"네온 사인",
         "네온 사인처럼 발광하는 굵은 글자. 글자 자체가 빛을 내고 주변에 은은한 글로우가 번진다. 어두운 배경에서 가장 잘 보인다."},
        {"깔끔한 산세리프",
         "장식 없는 굵은 산세리프. 발광이나 그림자 없이 단색으로 또렷하게. 필요하면 얇은 외곽선만 넣어 배경과 분리한다."},
        {"방송 자막 스타일",
         "뉴스·다큐 자막처럼 반투명 띠 위에 올린 단정한 글자. 띠는 배경을 가리지 않을 정도로만 어둡게."},
        {"손글씨 노트",
         "펜으로 쓴 듯한 손글씨. 살짝 기울고 굵기가 일정하지 않다. 밑줄이나 동그라미도 손으로 그은 느낌으로."},
        {"금속 각인",
         "금속판에 새긴 듯한 입체 글자. 모서리에 빛 반사가 있고 표면에 미세한 질감이 보인다."},
        {"종이 인쇄",
         "인쇄물처럼 평평하고 차분한 글자. 발광 없음. 교과서 도해에 가까운 절제된 표기."}
      ],
      "그래픽효과" => [
        {"네온 발광",
         "발광, 네온 글로우, 밝은 외곽선, 반투명 컬러 면, 라이트 트레일, 스캔 효과, 에너지 라인, 깊이감 있는 그래픽 레이어를 적극적으로 사용하라."},
        {"플랫 미니멀",
         "발광과 그림자를 쓰지 않는다. 단색 면, 또렷한 선, 단순한 도형만으로 구성하라. 색은 적게 쓰고 대비로 구분하라."},
        {"제도 도면",
         "제도 도면처럼 가는 실선, 치수선, 지시선, 해칭으로 표현하라. 발광 대신 선 굵기와 점선·실선 구분으로 위계를 만들어라."},
        {"방송 그래픽",
         "방송 인포그래픽처럼 반투명 패널, 부드러운 그림자, 절제된 강조색을 쓰라. 과한 발광은 피하고 정보 위계를 또렷하게 하라."}
      ],
      # 이미지 안에 그려질 글꼴. 실제 폰트 파일이 아니라 생성기에 주는 지시문이다 —
      # 하드번하는 자막 폰트(subtitle_fonts/0)와는 다른 것이다. 섞으면 화면과 자막이 따로 논다.
      "이미지글꼴" => [
        {"굵은 고딕 — 기본", "굵은 고딕체. 획 굵기가 일정하고 끝이 각져 있다. 제목용으로 크게 쓴다."},
        {"두꺼운 제목 고딕", "아주 두꺼운 제목용 고딕. 획 사이 공간이 거의 없을 만큼 굵고, 글자 폭이 넓다."},
        {"둥근 고딕", "모서리가 둥근 고딕체. 획 끝이 동그랗게 마감되어 부드럽고 친근하다."},
        {"본문 고딕 — 얇게", "가는 고딕체. 정보량이 많을 때 쓴다. 배경과 대비를 충분히 준다."},
        {"명조 — 신문·다큐", "세로획이 굵고 가로획이 가는 명조체. 끝에 삼각 장식이 있다. 무게감 있는 주제에 쓴다."},
        {"붓글씨", "붓으로 쓴 서예체. 획의 굵기가 변하고 끝이 갈라진다. 역사·전통 주제에 쓴다."},
        {"손글씨", "펜으로 쓴 손글씨. 글자마다 기울기와 크기가 조금씩 다르다."},
        {"각진 스텐실", "스텐실로 찍은 듯 획이 끊긴 각진 글자. 군사·산업 주제에 쓴다."},
        {"디지털 모노스페이스", "폭이 일정한 고정폭 글꼴. 기술·데이터 주제에 쓴다."}
      ],
      "표기언어" => [
        {"한국어", "한국어"},
        {"영어", "영어"},
        {"일본어", "일본어"},
        {"중국어 간체", "중국어 간체"},
        {"스페인어", "스페인어"}
      ]
    }
  end

  @doc "이 변수에 고를 수 있는 선택지가 있으면 목록, 없으면 nil."
  def choices_for(name), do: Map.get(variable_choices(), name)

  @doc """
  자막 폰트 선택지. 이건 프롬프트가 아니라 실제 ffmpeg/ASS 설정이다.

  **이 PC 에 실제로 깔려 있는 폰트만 올린다.** 없는 폰트 이름을 주면
  글자가 두부(□□□)로 렌더된다 — 렌더가 끝난 뒤에야 보인다.
  """
  def subtitle_fonts do
    [
      {"맑은 고딕 (기본)", "Malgun Gothic"},
      {"본고딕 Black — 가장 굵음", "Noto Sans KR Black"},
      {"본고딕 Medium", "Noto Sans KR Medium"},
      {"본고딕 Light — 얇게", "Noto Sans KR Light"},
      {"나눔고딕 ExtraBold", "NanumGothicExtraBold"},
      {"나눔고딕", "NanumGothic"},
      {"굴림", "Gulim"},
      {"돋움", "Dotum"},
      {"바탕 — 명조체", "Batang"}
    ]
  end

  @doc "설정이 비었을 때 쓰는 자막 폰트."
  def default_subtitle_font, do: "Malgun Gothic"

  @doc """
  그림체를 복제한다.

  백지에서 새로 만들지 않는다 — 그림체는 긴 규칙 네 덩이에 변수 열 개가 딸려 있어서
  빈 폼으로는 아무도 못 채운다. 비슷한 걸 복사해 고치는 게 실제로 쓰는 방식이다.
  """
  def duplicate_style(%StylePreset{} = style, name) do
    name = String.trim(name)

    if name == "" do
      {:error, "이름을 넣으세요"}
    else
      %StylePreset{}
      |> StylePreset.changeset(%{
        name: name,
        slug: unique_slug(StylePreset, slugify(name, "style")),
        global_style: style.global_style,
        clean_rules: style.clean_rules,
        camera_rules: style.camera_rules,
        asset_definitions: style.asset_definitions,
        default_aspect: style.default_aspect,
        variables: style.variables
      })
      |> Repo.insert()
    end
  end

  # 한글 이름을 그대로 slug 로 쓰면 URL·파일명에서 깨진다. 한글은 음절을 못 옮기니
  # 영문·숫자만 남기고, 남는 게 없으면 시각으로 대체한다 — 이름은 화면에 보이고 slug 는 내부용이다.
  # 한글 이름은 그대로 slug 로 쓰면 URL·파일명에서 깨진다. 음절을 옮길 방법이 없으니
  # 영문·숫자만 남기고, 남는 게 없으면 종류 이름 + 시각으로 대체한다.
  # 종류를 접두사로 받는 이유: 예전엔 장르 slug 도 'style-...' 로 나와 헷갈렸다.
  defp slugify(name, kind) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    if base == "", do: "#{kind}-#{System.os_time(:second)}", else: base
  end

  defp unique_slug(schema, base, n \\ 0) do
    candidate = if n == 0, do: base, else: "#{base}-#{n}"

    case Repo.get_by(schema, slug: candidate) do
      nil -> candidate
      _ -> unique_slug(schema, base, n + 1)
    end
  end

  @doc """
  빈 그림체를 만든다.

  복제가 기본이지만 완전히 다른 화풍을 시작할 때는 남의 규칙이 오히려 방해가 된다.
  변수는 프롬프트가 참조하는 이름이라 비워두면 ⟨미설정⟩ 으로 렌더되므로,
  기존 그림체의 변수 **이름만** 가져오고 값은 비운다.
  """
  def create_style(name) do
    name = String.trim(name)

    if name == "" do
      {:error, "이름을 넣으세요"}
    else
      keys =
        case list_styles() do
          [ref | _] -> Map.keys(ref.variables || %{})
          [] -> []
        end

      %StylePreset{}
      |> StylePreset.changeset(%{
        name: name,
        slug: unique_slug(StylePreset, slugify(name, "style")),
        variables: Map.new(keys, &{&1, ""})
      })
      |> Repo.insert()
    end
  end

  @doc """
  이름만 받아 바로 쓸 수 있는 그림체를 만든다. 반복 제작 폼에서 없는 이름을 적었을 때 부른다.

  빈 그림체를 만들면 프롬프트가 ⟨미설정⟩ 으로 렌더돼 못 쓴다. 그렇다고 기존 그림체를
  그대로 복사하면 이름만 다르고 그림이 똑같아진다 — 고른 의미가 없다.
  그래서 **적어 넣은 이름을 실제 규칙 문장에 꽂아** 최소한 그 화풍으로 시도는 하게 만든다.
  세부는 /prompts 에서 다듬는다.
  """
  def create_style_from_name(name) do
    name = String.trim(name)

    if name == "" do
      {:error, "이름을 넣으세요"}
    else
      # 변수 키는 기존 그림체에서 가져온다. 키가 빠지면 프롬프트에 ⟨미설정⟩ 이 남는다.
      vars =
        case list_styles() do
          [ref | _] -> Map.merge(ref.variables || %{}, name_vars(name))
          [] -> name_vars(name)
        end

      %StylePreset{}
      |> StylePreset.changeset(%{
        name: name,
        slug: unique_slug(StylePreset, slugify(name, "style")),
        global_style: """
        GLOBAL STYLE
        #{name} 화풍으로 그린다. 이 화풍의 전형적인 재질, 선, 색 처리, 조명을 따른다.
        모든 컷에서 같은 화풍을 유지한다 — 컷마다 그림체가 달라지면 한 영상으로 안 보인다.
        """,
        clean_rules: """
        모든 장면은 다음 기준을 지킨다.
        - 화면에 텍스트·숫자·화살표·라벨·아이콘·경로선을 넣지 않는다
        - #{name} 화풍을 모든 컷에서 동일하게 유지한다
        - 같은 대상은 모든 컷에서 같은 형태·색으로 유지한다
        - 화면 아래 20퍼센트는 자막 자리이므로 핵심 대상을 두지 않는다
        """,
        camera_rules: """
        #{name} 화풍에서 자연스러운 카메라 움직임만 쓴다.
        한 컷 안에서 카메라 동작은 하나만 쓴다.
        이 화풍에서 불가능하거나 어색한 움직임은 쓰지 않는다.
        """,
        asset_definitions: """
        여러 컷에 반복 등장하는 대상은 첫 등장 때의 형태·색·비율을 그대로 유지한다.
        """,
        variables: vars
      })
      |> Repo.insert()
    end
  end

  defp name_vars(name) do
    %{
      "렌더링" => name,
      "영상성격" => "#{name} 화풍 장면의 키프레임",
      "최종품질" => "#{name} 화풍으로 완성도 높게 그린 영상의 키프레임"
    }
  end

  @doc "이름만 받아 장르를 만든다. 반복 제작 폼에서 없는 이름을 적었을 때 부른다."
  def create_domain_from_name(name) do
    name = String.trim(name)

    if name == "" do
      {:error, "이름을 넣으세요"}
    else
      %DomainPreset{}
      |> DomainPreset.changeset(%{
        name: name,
        slug: unique_slug(DomainPreset, slugify(name, "domain")),
        info_rules: """
        #{name} 특화 기준
        - 수치는 단위와 함께 쓰고, 허용 목록에 있는 것만 쓴다
        - 확실한 것과 추정을 구분해 표시한다 (추정은 점선)
        - 브랜드·제품명·로고를 넣지 않는다
        - 이 분야에서 오해를 부르거나 단정으로 읽히는 표현을 쓰지 않는다
        """,
        element_list: """
        사용 가능 요소: 화살표, 강조 링, 경계선, 경로선, 호출선, 측정선,
        비교 막대, 타임라인, 단면 강조, 범례, 단계 번호, 강조 외곽선
        """,
        color_semantics: %{"핵심" => "빨강", "보조" => "파랑", "흐름" => "주황", "중립" => "회색"},
        video_topic_rules: """
        주제별 자동 적용
        - 순서 설명: 단계 번호대로 요소가 하나씩 등장한다
        - 비교: 같은 축척으로 나란히 놓고 차이를 강조한다
        - 흐름: 경로선이 시작에서 끝으로 순서대로 뻗는다
        """
      })
      |> Repo.insert()
    end
  end

  def delete_style(%StylePreset{} = style) do
    # 쓰고 있는 프로젝트가 있으면 지우지 않는다. 지우면 그 프로젝트들의 프롬프트가 통째로 비어버린다.
    used = Repo.aggregate(from(p in VideoTool.Projects.Project, where: p.style_id == ^style.id), :count)

    if used > 0 do
      {:error, "프로젝트 #{used}개가 이 그림체를 쓰고 있습니다. 먼저 다른 그림체로 옮기세요"}
    else
      Repo.delete(style)
    end
  end

  # 장르도 그림체와 같다 — 규칙 네 덩이에 색 의미까지 딸려 있어 백지에서 못 채운다.
  def duplicate_domain(%DomainPreset{} = d, name) do
    name = String.trim(name)

    if name == "" do
      {:error, "이름을 넣으세요"}
    else
      %DomainPreset{}
      |> DomainPreset.changeset(%{
        name: name,
        slug: unique_slug(DomainPreset, slugify(name, "domain")),
        info_rules: d.info_rules,
        element_list: d.element_list,
        color_semantics: d.color_semantics,
        video_topic_rules: d.video_topic_rules,
        variables: d.variables
      })
      |> Repo.insert()
    end
  end

  def create_domain(name) do
    name = String.trim(name)

    if name == "" do
      {:error, "이름을 넣으세요"}
    else
      %DomainPreset{}
      |> DomainPreset.changeset(%{name: name, slug: unique_slug(DomainPreset, slugify(name, "domain"))})
      |> Repo.insert()
    end
  end

  def delete_domain(%DomainPreset{} = d) do
    used = Repo.aggregate(from(p in VideoTool.Projects.Project, where: p.domain_id == ^d.id), :count)

    if used > 0 do
      {:error, "프로젝트 #{used}개가 이 장르를 쓰고 있습니다. 먼저 다른 장르로 옮기세요"}
    else
      Repo.delete(d)
    end
  end

  def get_domain_by_id!(id), do: Repo.get!(DomainPreset, id)

  def update_style(%StylePreset{} = style, attrs),
    do: style |> StylePreset.changeset(attrs) |> Repo.update()

  def update_domain(%DomainPreset{} = domain, attrs),
    do: domain |> DomainPreset.changeset(attrs) |> Repo.update()

  def get_style!(id), do: Repo.get!(StylePreset, id)
  def get_domain!(id), do: Repo.get!(DomainPreset, id)

  @doc """
  TTS 실측 결과를 보이스에 되먹인다. 누적 평균이라 한 번의 이상치가 값을 통째로 흔들지 않는다.
  """
  def record_measurement(%Voice{} = voice, measured_cps) when is_number(measured_cps) do
    n = voice.sample_count
    blended = (voice.chars_per_sec * n + measured_cps) / (n + 1)

    voice
    |> Voice.changeset(%{chars_per_sec: blended, sample_count: n + 1})
    |> Repo.update()
  end
end