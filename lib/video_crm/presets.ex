defmodule VideoCRM.Presets.StylePreset do
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

defmodule VideoCRM.Presets.DomainPreset do
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

defmodule VideoCRM.Presets.Voice do
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

    timestamps(type: :utc_datetime)
  end

  @fields ~w(provider voice_id variant display_name slug lang chars_per_sec
             sample_count is_default)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:voice_id, :display_name, :slug])
    |> validate_number(:chars_per_sec, greater_than: 0)
    |> unique_constraint(:slug)
  end
end

defmodule VideoCRM.Presets.PromptTemplate do
  @moduledoc "단계별 프롬프트 뼈대. 자리표시자는 VideoCRM.Prompt 참조."
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

defmodule VideoCRM.Presets do
  @moduledoc "프리셋 조회. 프로젝트 생성 시 slug 로 참조한다."

  import Ecto.Query
  alias VideoCRM.Repo
  alias VideoCRM.Presets.{StylePreset, DomainPreset, Voice, PromptTemplate}

  def list_styles, do: Repo.all(from s in StylePreset, where: s.is_active, order_by: s.name)
  def list_domains, do: Repo.all(from d in DomainPreset, where: d.is_active, order_by: d.name)
  def list_voices, do: Repo.all(from v in Voice, order_by: v.display_name)

  def list_templates,
    do: Repo.all(from t in PromptTemplate, where: t.is_active, order_by: [t.stage, t.version])

  def fetch_style(slug), do: fetch_by_slug(StylePreset, slug, "그림체")
  def fetch_domain(slug), do: fetch_by_slug(DomainPreset, slug, "장르")
  def fetch_voice(slug), do: fetch_by_slug(Voice, slug, "보이스")

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