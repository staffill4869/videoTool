defmodule VideoTool.Projects.Project do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Presets.{StylePreset, DomainPreset, Voice}

  @statuses ~w(draft scripted scened clean_done info_done clips_done narrated assembled done)

  # 화면·나레이션에 쓸 언어. 코드는 자유롭게 추가할 수 있고, 모르는 코드는 코드 그대로 쓴다.
  @language_names %{
    "ko" => "한국어",
    "en" => "영어(English)",
    "ja" => "일본어(日本語)",
    "zh" => "중국어 간체(简体中文)",
    "zh-TW" => "중국어 번체(繁體中文)",
    "es" => "스페인어(Español)",
    "pt" => "포르투갈어(Português)",
    "id" => "인도네시아어(Bahasa Indonesia)",
    "vi" => "베트남어(Tiếng Việt)",
    "hi" => "힌디어(हिन्दी)",
    "de" => "독일어(Deutsch)",
    "fr" => "프랑스어(Français)"
  }

  def language_names, do: @language_names
  def language_label(code), do: Map.get(@language_names, code, code)

  # ai        — Flow 를 사람이 조작한다 (프롬프트는 클립보드로 받는다)
  # flow_auto — Flow 를 브라우저 자동 조종으로 돌린다
  # blender / hybrid — 아직 없다
  @pipelines ~w(ai flow_auto blender hybrid)

  schema "projects" do
    field :title, :string
    field :topic, :string, default: ""
    field :target_sec, :integer, default: 60
    field :aspect, :string, default: "16:9"
    field :pipeline, :string, default: "flow_auto"
    field :status, :string, default: "draft"
    field :work_dir, :string, default: ""
    field :output_folder, :string, default: ""
    # 이 프로젝트에서만 쓸 프롬프트. 값이 있으면 템플릿 대신 이걸 쓴다.
    field :prompt_overrides, :map, default: %{}
    # 이 프로젝트에서만 덮어쓸 {{var.*}} 값.
    field :variables, :map, default: %{}
    field :series_id, :id
    # 자막을 구울 실제 폰트 이름. 비어 있으면 기본값을 쓴다.
    # 이 PC 에 없는 폰트를 넣으면 글자가 두부로 나온다 — 선택지는 Presets.subtitle_fonts/0 에.
    field :subtitle_font, :string, default: ""
    field :language, :string, default: "ko"
    # 언어판이면 원본 프로젝트. CLEAN 이미지를 원본과 공유한다.
    field :variant_of_id, :id

    belongs_to :style, StylePreset
    belongs_to :domain, DomainPreset
    belongs_to :voice, Voice

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def pipelines, do: @pipelines

  @doc "상태 순서. 되돌아가는 전이는 허용하지만 순서 자체는 여기서만 정의한다."
  def status_index(status), do: Enum.find_index(@statuses, &(&1 == status))

  @fields ~w(title topic target_sec aspect pipeline status work_dir output_folder
             prompt_overrides variables series_id language variant_of_id
             subtitle_font style_id domain_id voice_id)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:title, :style_id, :domain_id, :voice_id])
    |> validate_inclusion(:aspect, ["16:9", "9:16"])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:pipeline, @pipelines)
    |> validate_number(:target_sec, greater_than: 0)
    |> assoc_constraint(:style)
    |> assoc_constraint(:domain)
    |> assoc_constraint(:voice)
  end
end

defmodule VideoTool.Projects.Script do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Projects.Project

  # screen_matched: 이미지를 이미 만든 뒤 화면에 맞춰 대본을 고친 경우. 실제로 겪은 케이스라 구분한다.
  @sources ~w(draft revised screen_matched)

  schema "scripts" do
    field :version, :integer, default: 1
    field :raw_text, :string, default: ""
    field :tts_text, :string, default: ""
    field :estimated_sec, :float, default: 0.0
    field :actual_sec, :float
    field :source, :string, default: "draft"
    field :is_active, :boolean, default: true

    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  def sources, do: @sources

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(project_id version raw_text tts_text estimated_sec actual_sec
                      source is_active)a)
    |> validate_required([:project_id, :version, :raw_text])
    |> validate_inclusion(:source, @sources)
    |> unique_constraint([:project_id, :version])
  end
end

defmodule VideoTool.Projects.Scene do
  @moduledoc """
  Project 에 붙는 고정 슬롯이다. Script 에 매달면 대본을 고칠 때 Scene 이 새로 생기면서
  이미 생성한 이미지 연결이 끊어진다 — 실제로 "이미지는 두고 대본만 고치는" 상황이 있었다.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Projects.Project

  @purposes ~w(hook setup turn payoff close)

  schema "scenes" do
    field :scene_no, :integer
    field :target_sec, :float, default: 0.0
    field :purpose, :string, default: "setup"
    field :shot_prompt, :string, default: ""
    field :info_instruction, :string, default: ""
    field :camera_plan, :map, default: %{}
    field :use_fast_zoom, :boolean, default: false
    # 순서 자동 매핑의 근거. INFO 이미지를 OCR 해서 이 값과 대조한다.
    field :expected_labels, {:array, :string}, default: []

    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  def purposes, do: @purposes

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(project_id scene_no target_sec purpose shot_prompt info_instruction
                      camera_plan use_fast_zoom expected_labels)a)
    |> validate_required([:project_id, :scene_no])
    |> validate_inclusion(:purpose, @purposes)
    |> validate_number(:scene_no, greater_than: 0)
    |> unique_constraint([:project_id, :scene_no])
  end
end

defmodule VideoTool.Projects.ScriptSegment do
  @moduledoc "대본 구간만 버전별로 갈아끼운다. Scene 은 그대로 둔다."
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Projects.{Script, Scene}

  schema "script_segments" do
    field :text, :string, default: ""
    field :order, :integer, default: 0

    belongs_to :script, Script
    belongs_to :scene, Scene

    timestamps(type: :utc_datetime)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(script_id scene_id text order)a)
    |> validate_required([:script_id, :scene_id])
    |> unique_constraint([:script_id, :scene_id])
  end
end

defmodule VideoTool.Projects.AllowedFact do
  @moduledoc """
  허용 수치·명칭 화이트리스트. Flow 가 근거 없는 수치를 지어내는 것을 막는 유일한 수단이다
  ("근거 없는 수치 금지" 라고 쓰는 것으로는 막히지 않았다).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Projects.Script

  @kinds ~w(number place person date)

  schema "allowed_facts" do
    field :kind, :string, default: "number"
    field :value, :string
    field :note, :string, default: ""

    belongs_to :script, Script

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(script_id kind value note)a)
    |> validate_required([:script_id, :value])
    |> validate_inclusion(:kind, @kinds)
  end
end

defmodule VideoTool.Projects do
  @moduledoc "프로젝트 · 대본 · 장면. 에이전트가 만든 결과물을 받아 저장한다."

  import Ecto.Query
  alias Ecto.Multi
  alias VideoTool.{Presets, Repo}
  alias VideoTool.Projects.{Project, Script, Scene, ScriptSegment, AllowedFact}

  # 언어 표기는 스키마에 있지만 부르는 쪽은 컨텍스트만 알면 되게 한다.
  defdelegate language_label(code), to: Project
  defdelegate language_names(), to: Project

  # ── 조회 ────────────────────────────────────────────────────────

  def get_project(id) do
    case Repo.get(Project, id) do
      nil -> {:error, "프로젝트 #{id} 을(를) 찾을 수 없습니다"}
      p -> {:ok, Repo.preload(p, [:style, :domain, :voice])}
    end
  end

  def list_projects,
    do: Repo.all(from p in Project, order_by: [desc: p.updated_at], preload: [:voice])

  def active_script(project_id) do
    query =
      from s in Script,
        where: s.project_id == ^project_id and s.is_active,
        order_by: [desc: s.version],
        limit: 1

    Repo.one(query)
  end

  def scenes(project_id),
    do: Repo.all(from s in Scene, where: s.project_id == ^project_id, order_by: s.scene_no)

  def allowed_facts(nil), do: []

  def allowed_facts(script_id),
    do: Repo.all(from f in AllowedFact, where: f.script_id == ^script_id, order_by: f.id)

  @doc "장면별 대본 구간을 %{scene_id => text} 로."
  def segments_by_scene(nil), do: %{}

  def segments_by_scene(script_id) do
    from(g in ScriptSegment, where: g.script_id == ^script_id)
    |> Repo.all()
    |> Map.new(&{&1.scene_id, &1.text})
  end

  @doc """
  장면 순서대로 정렬한 대본 구간. 나레이션 정렬이 순서에 의존하므로
  `order` 가 아니라 실제 장면 번호로 정렬한다 — 둘이 어긋난 적이 있다.
  """
  def segments_for(nil), do: []

  def segments_for(script_id) do
    from(g in ScriptSegment,
      join: s in Scene,
      on: s.id == g.scene_id,
      where: g.script_id == ^script_id,
      order_by: s.scene_no,
      select: %{scene_id: g.scene_id, text: g.text, scene_no: s.scene_no}
    )
    |> Repo.all()
  end

  # ── 대본 길이 계산 ──────────────────────────────────────────────

  @doc """
  공백을 뺀 글자 수를 보이스의 실측 초당 글자수로 나눈다.
  대본을 쓰기 전에 반드시 부른다 — 안 부르면 60초 대본이 130초로 나온다.
  """
  def estimate_length(voice, text) do
    chars = countable_chars(text)
    est = chars / voice.chars_per_sec
    %{chars: chars, estimated_sec: Float.round(est, 1), chars_per_sec: voice.chars_per_sec}
  end

  @doc "공백을 제외한 글자 수. 장면별 시간 배분에서도 같은 기준을 쓴다."
  def countable_chars(nil), do: 0

  def countable_chars(text) do
    text
    |> String.replace(~r/\s+/u, "")
    |> String.length()
  end

  # ── 저장 ────────────────────────────────────────────────────────

  def create_project(attrs) do
    with {:ok, style} <- Presets.fetch_style(attrs["style_slug"]),
         {:ok, domain} <- Presets.fetch_domain(attrs["domain_slug"]),
         {:ok, voice} <- Presets.fetch_voice(attrs["voice_slug"]) do
      params =
        attrs
        |> Map.take([
          "title",
          "topic",
          "target_sec",
          "aspect",
          "output_folder",
          "pipeline",
          "variables",
          "language",
          "subtitle_font"
        ])
        |> Map.merge(%{
          "style_id" => style.id,
          "domain_id" => domain.id,
          "voice_id" => voice.id,
          "aspect" => attrs["aspect"] || style.default_aspect
        })

      with {:ok, project} <- %Project{} |> Project.changeset(params) |> Repo.insert() do
        # 작업 폴더는 id 가 정해진 뒤에만 만들 수 있다.
        work_dir = Path.join(work_root(), Integer.to_string(project.id))
        File.mkdir_p!(work_dir)

        project
        |> Project.changeset(%{work_dir: work_dir})
        |> Repo.update()
      end
    end
  end

  def work_root do
    Application.get_env(:video_tool, :work_root) || Path.join(File.cwd!(), "projects")
  end

  @doc "새 버전을 만들고 이전 버전의 is_active 를 내린다."
  def save_script(project, raw_text, tts_text, source) do
    next_version =
      Repo.one(from s in Script, where: s.project_id == ^project.id, select: max(s.version)) || 0

    est = estimate_length(project.voice, tts_text || raw_text)

    params = %{
      project_id: project.id,
      version: next_version + 1,
      raw_text: raw_text,
      tts_text: tts_text || raw_text,
      estimated_sec: est.estimated_sec,
      source: source || "draft"
    }

    Multi.new()
    |> Multi.update_all(
      :deactivate,
      from(s in Script, where: s.project_id == ^project.id),
      set: [is_active: false]
    )
    |> Multi.insert(:script, Script.changeset(%Script{}, params))
    |> Multi.update(:project, Project.changeset(project, %{status: "scripted"}))
    |> Repo.transaction()
    |> case do
      {:ok, %{script: script}} -> {:ok, script, est}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  # Flow 클립은 **무조건 8초로 나온다.** 장면 target_sec 은 목표가 아니라 사실이다.
  # 60초를 16장면으로 쪼개 각 3.85초로 적으면, 화면은 16×8=128초가 되어 대본의 두 배가 된다.
  # 실제로 57번이 그랬다 — CLEAN·INFO·VIDEO 를 16개씩 48번 만들어 크레딧이 두 배 나갔고,
  # 클립이 많아 VIDEO 단계가 900초 안에 못 끝내고 실패했다.
  @clip_sec 8

  defp check_scene_count(project, scene_maps) do
    want = max(round(project.target_sec / @clip_sec), 1)
    got = length(scene_maps)

    if got > want * 1.5 do
      {:error,
       "장면이 #{got}개입니다. #{project.target_sec}초짜리면 #{want}개여야 합니다 — " <>
         "Flow 클립은 길이를 지정할 수 없고 항상 #{@clip_sec}초로 나옵니다. " <>
         "#{got}개를 만들면 화면이 #{got * @clip_sec}초가 되어 대본보다 길어지고, " <>
         "생성도 #{got * 3}번 돌아 크레딧이 그만큼 더 나갑니다. " <>
         "길이를 늘리려면 장면을 쪼개지 말고 시리즈의 target_sec 을 올리세요."}
    else
      :ok
    end
  end

  @doc """
  scene_no 기준 upsert. 기존 Scene 을 지우지 않으므로 이미 붙은 Asset 연결이 유지된다.
  대본 구간은 활성 Script 에 붙여 따로 갈아끼운다.
  """
  def save_scenes(project, scene_maps) when is_list(scene_maps) do
    with :ok <- check_scene_count(project, scene_maps) do
      do_save_scenes(project, scene_maps)
    end
  end

  defp do_save_scenes(project, scene_maps) do
    script = active_script(project.id)
    existing = Map.new(scenes(project.id), &{&1.scene_no, &1})

    result =
      Enum.reduce_while(scene_maps, {0, 0, []}, fn attrs, {created, updated, saved} ->
        scene_no = attrs["scene_no"]
        current = Map.get(existing, scene_no)

        # 안 보낸 키는 아예 빼야 한다. nil 을 그대로 cast 하면 기존 값이 지워지고
        # not-null 컬럼에서 터진다 — 부분 수정("이 컷 문장만 고쳐줘")이 정상 경로다.
        params =
          %{
            "target_sec" => attrs["target_sec"],
            "purpose" => attrs["purpose"],
            "shot_prompt" => attrs["shot_prompt"],
            "info_instruction" => attrs["info_instruction"],
            "camera_plan" => attrs["camera_plan"],
            "use_fast_zoom" => attrs["use_fast_zoom"],
            "expected_labels" => attrs["expected_labels"]
          }
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.merge(%{"project_id" => project.id, "scene_no" => scene_no})

        changeset =
          case current do
            nil -> Scene.changeset(%Scene{}, params)
            row -> Scene.changeset(row, params)
          end

        case Repo.insert_or_update(changeset) do
          {:ok, scene} ->
            maybe_save_segment(script, scene, attrs["segment_text"], scene_no)

            case current do
              nil -> {:cont, {created + 1, updated, [scene | saved]}}
              _ -> {:cont, {created, updated + 1, [scene | saved]}}
            end

          {:error, changeset} ->
            {:halt, {:error, changeset}}
        end
      end)

    case result do
      {:error, changeset} ->
        {:error, changeset}

      {created, updated, saved} ->
        total = saved |> Enum.map(& &1.target_sec) |> Enum.sum()
        {:ok, project} = project |> Project.changeset(%{status: "scened"}) |> Repo.update()
        {:ok, %{created: created, updated: updated, total_target_sec: total, project: project}}
    end
  end

  defp maybe_save_segment(nil, _scene, _text, _order), do: :ok
  defp maybe_save_segment(_script, _scene, nil, _order), do: :ok

  defp maybe_save_segment(script, scene, text, order) do
    params = %{script_id: script.id, scene_id: scene.id, text: text, order: order}

    case Repo.get_by(ScriptSegment, script_id: script.id, scene_id: scene.id) do
      nil -> %ScriptSegment{}
      row -> row
    end
    |> ScriptSegment.changeset(params)
    |> Repo.insert_or_update()
  end

  @doc "화이트리스트는 통째로 교체한다 — 대본이 바뀌면 허용 목록도 통째로 바뀐다."
  def save_allowed_facts(script, facts) when is_list(facts) do
    Multi.new()
    |> Multi.delete_all(:clear, from(f in AllowedFact, where: f.script_id == ^script.id))
    |> Multi.insert_all(
      :insert,
      AllowedFact,
      fn _ ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Enum.map(facts, fn f ->
          %{
            script_id: script.id,
            kind: f["kind"] || "number",
            value: f["value"],
            note: f["note"] || "",
            inserted_at: now,
            updated_at: now
          }
        end)
      end
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{insert: {count, _}}} -> {:ok, count}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  def set_status(project, status) do
    project |> Project.changeset(%{status: status}) |> Repo.update()
  end

  def set_pipeline(project, pipeline) do
    project |> Project.changeset(%{pipeline: pipeline}) |> Repo.update()
  end

  @doc """
  이 프로젝트에서만 쓸 프롬프트를 저장한다. `body` 가 nil 이거나 빈 문자열이면 지운다
  (= 다시 공용 템플릿을 쓴다).
  """
  def set_prompt_override(project, stage, body) do
    overrides = project.prompt_overrides || %{}

    updated =
      if is_nil(body) or String.trim(body) == "" do
        Map.delete(overrides, stage)
      else
        Map.put(overrides, stage, body)
      end

    project |> Project.changeset(%{prompt_overrides: updated}) |> Repo.update()
  end

  def set_variables(project, variables) when is_map(variables) do
    project |> Project.changeset(%{variables: variables}) |> Repo.update()
  end

  def update_project(project, attrs) do
    project |> Project.changeset(attrs) |> Repo.update()
  end

  @doc """
  프로젝트와 딸린 것을 전부 지운다. 파일은 지우지 않는다 — 되돌릴 여지를 남긴다.

  단순 `Repo.delete` 로는 자식 레코드의 외래키에 걸려 실패한다.
  의존 순서대로 아래에서 위로 지운다.
  """
  def delete_project(%Project{} = project) do
    id = project.id

    Repo.transaction(fn ->
      sql = fn q, params -> Ecto.Adapters.SQL.query!(Repo, q, params) end

      # 손자부터 (부모를 지우기 전에 참조를 끊는다)
      sql.("delete from metrics where publication_id in (select id from publications where project_id = $1)", [id])
      sql.("delete from subtitles where narration_id in (select id from narrations where project_id = $1)", [id])
      sql.("delete from renders where project_id = $1", [id])
      sql.("delete from narrations where project_id = $1", [id])
      sql.("delete from allowed_facts where script_id in (select id from scripts where project_id = $1)", [id])
      sql.("delete from script_segments where script_id in (select id from scripts where project_id = $1)", [id])
      sql.("delete from assets where project_id = $1", [id])
      sql.("delete from scenes where project_id = $1", [id])
      sql.("delete from scripts where project_id = $1", [id])
      sql.("delete from publications where project_id = $1", [id])
      sql.("delete from generation_jobs where project_id = $1", [id])
      sql.("delete from ingest_jobs where project_id = $1", [id])
      sql.("delete from validations where project_id = $1", [id])
      sql.("delete from projects where id = $1", [id])

      project
    end)
  end

  @doc """
  같은 영상의 다른 언어판을 만든다.

  **CLEAN 이미지를 다시 만들지 않는다.** CLEAN 에는 글자가 없으므로 언어가 달라도 그대로 쓴다.
  다시 만들어야 하는 것은 INFO(라벨이 그 언어로 들어간다)와 나레이션·자막뿐이다.
  CLEAN/INFO 를 나눠둔 설계가 여기서 값을 한다 — 언어를 하나 늘리는 비용이 3분의 1로 줄어든다.

  장면(shot_prompt·camera_plan·target_sec)은 그대로 복사한다. 화면 구성은 언어와 무관하다.
  `expected_labels` 는 비운다 — 그 언어로 다시 정해야 한다.
  """
  def create_language_variant(source, language, opts \\ []) do
    voice =
      case opts[:voice_slug] do
        nil -> {:ok, source.voice}
        slug -> Presets.fetch_voice(slug)
      end

    with {:ok, voice} <- voice do
      attrs = %{
        "title" => opts[:title] || "#{source.title} [#{language_label(language)}]",
        "topic" => source.topic,
        "target_sec" => source.target_sec,
        "aspect" => source.aspect,
        "style_slug" => source.style.slug,
        "domain_slug" => source.domain.slug,
        "voice_slug" => voice.slug,
        "output_folder" => source.output_folder,
        "pipeline" => source.pipeline
      }

      with {:ok, variant} <- create_project(attrs),
           {:ok, variant} <-
             update_project(variant, %{
               language: language,
               variant_of_id: source.id,
               series_id: source.series_id,
               prompt_overrides: source.prompt_overrides,
               variables: source.variables
             }) do
        copy_scenes(source, variant)
        copied = copy_clean_assets(source, variant)

        {:ok, %{project: variant, scenes: length(scenes(variant.id)), clean_reused: copied}}
      end
    end
  end

  defp copy_scenes(source, variant) do
    for scene <- scenes(source.id) do
      %Scene{}
      |> Scene.changeset(%{
        project_id: variant.id,
        scene_no: scene.scene_no,
        target_sec: scene.target_sec,
        purpose: scene.purpose,
        shot_prompt: scene.shot_prompt,
        info_instruction: scene.info_instruction,
        camera_plan: scene.camera_plan,
        use_fast_zoom: scene.use_fast_zoom,
        # 라벨은 그 언어로 다시 정해야 한다.
        expected_labels: []
      })
      |> Repo.insert!()
    end
  end

  # 파일을 복사하지 않고 같은 경로를 가리킨다. 같은 그림이니 두 벌 둘 이유가 없다.
  defp copy_clean_assets(source, variant) do
    scene_map = Map.new(scenes(variant.id), &{&1.scene_no, &1.id})
    source_scenes = Map.new(scenes(source.id), &{&1.id, &1.scene_no})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      from(a in VideoTool.Media.Asset,
        where: a.project_id == ^source.id and a.kind == "clean" and not is_nil(a.scene_id)
      )
      |> Repo.all()
      |> Enum.map(fn asset ->
        %{
          project_id: variant.id,
          scene_id: Map.get(scene_map, Map.get(source_scenes, asset.scene_id)),
          kind: "clean",
          source: asset.source,
          file_path: asset.file_path,
          source_filename: asset.source_filename,
          phash: asset.phash,
          phash_last: asset.phash_last,
          width: asset.width,
          height: asset.height,
          duration_sec: asset.duration_sec,
          fps: asset.fps,
          order_confidence: asset.order_confidence,
          status: asset.status,
          reject_reason: "",
          inserted_at: now,
          updated_at: now
        }
      end)
      |> Enum.reject(&is_nil(&1.scene_id))

    {count, _} = Repo.insert_all(VideoTool.Media.Asset, entries)
    count
  end

  @doc "이 프로젝트의 언어판들."
  def variants(project_id) do
    Repo.all(from p in Project, where: p.variant_of_id == ^project_id, order_by: p.id)
  end
end