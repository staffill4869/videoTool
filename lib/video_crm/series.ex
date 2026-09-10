defmodule VideoCRM.Series.Recipe do
  @moduledoc """
  반복 제작 설정. 한 번 정해두면 간격마다 프로젝트가 하나씩 생긴다.

  **제작만 자동이고 발행은 아니다.** 만들어진 프로젝트는 대본이 비어 있는 상태로 대기하고,
  대본은 에이전트가 쓴다(서버에는 LLM 이 없다). 발행은 사람이 누를 때만 나간다.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoCRM.Presets.{StylePreset, DomainPreset, Voice}

  schema "series" do
    field :name, :string
    field :topic_brief, :string, default: ""
    # "계속 하나의 프롬프트로 찍어낸다" 의 그 프롬프트.
    field :standing_prompt, :string, default: ""

    field :aspect, :string, default: "16:9"
    # 만들 언어들. 첫 번째가 원본, 나머지는 CLEAN 을 재사용하는 언어판이다.
    field :languages, {:array, :string}, default: ["ko"]
    field :target_sec, :integer, default: 60
    field :pipeline, :string, default: "ai"
    field :output_folder, :string, default: ""

    field :interval_minutes, :integer, default: 0
    field :active, :boolean, default: false
    field :max_pending, :integer, default: 3

    field :last_run_at, :utc_datetime
    field :next_run_at, :utc_datetime
    field :last_error, :string, default: ""
    field :created_count, :integer, default: 0

    belongs_to :style, StylePreset
    belongs_to :domain, DomainPreset
    belongs_to :voice, Voice

    timestamps(type: :utc_datetime)
  end

  @fields ~w(name topic_brief standing_prompt aspect languages target_sec pipeline output_folder
             interval_minutes active max_pending style_id domain_id voice_id
             last_run_at next_run_at last_error created_count)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:name, :style_id, :domain_id, :voice_id])
    |> validate_inclusion(:aspect, ["16:9", "9:16"])
    |> validate_inclusion(:pipeline, VideoCRM.Projects.Project.pipelines())
    |> validate_number(:target_sec, greater_than: 0)
    # 0 = 자동 생성 안 함. 1분 미만은 실수로 보고 막는다 — 분당 한 편은 만들 수 없다.
    |> validate_number(:interval_minutes, greater_than_or_equal_to: 0)
    |> validate_number(:max_pending, greater_than: 0, less_than_or_equal_to: 50)
    |> assoc_constraint(:style)
    |> assoc_constraint(:domain)
    |> assoc_constraint(:voice)
  end
end

defmodule VideoCRM.Series do
  @moduledoc "반복 제작 설정 관리와 실행."

  import Ecto.Query
  require Logger

  alias VideoCRM.{Projects, Repo}
  alias VideoCRM.Projects.Project
  alias VideoCRM.Series.Recipe

  def list do
    Repo.all(from s in Recipe, order_by: [desc: s.updated_at], preload: [:style, :domain, :voice])
  end

  def get(id) do
    case Repo.get(Recipe, id) |> Repo.preload([:style, :domain, :voice]) do
      nil -> {:error, "시리즈 #{id} 을(를) 찾을 수 없습니다"}
      s -> {:ok, s}
    end
  end

  def create(attrs) do
    %Recipe{}
    |> Recipe.changeset(attrs)
    |> put_next_run()
    |> Repo.insert()
  end

  def update(%Recipe{} = series, attrs) do
    series
    |> Recipe.changeset(attrs)
    |> put_next_run()
    |> Repo.update()
  end

  @doc "삭제해도 만들어진 프로젝트는 남는다 (series_id 만 비워진다)."
  def delete(%Recipe{} = series), do: Repo.delete(series)

  # 간격이나 활성 상태가 바뀌면 다음 실행 시각을 다시 잡는다.
  defp put_next_run(changeset) do
    active = Ecto.Changeset.get_field(changeset, :active)
    interval = Ecto.Changeset.get_field(changeset, :interval_minutes) || 0

    cond do
      not active or interval <= 0 ->
        Ecto.Changeset.put_change(changeset, :next_run_at, nil)

      Ecto.Changeset.changed?(changeset, :active) or
          Ecto.Changeset.changed?(changeset, :interval_minutes) ->
        Ecto.Changeset.put_change(changeset, :next_run_at, in_minutes(interval))

      true ->
        changeset
    end
  end

  defp in_minutes(minutes) do
    DateTime.utc_now() |> DateTime.add(minutes * 60, :second) |> DateTime.truncate(:second)
  end

  @doc """
  이 시리즈로 프로젝트를 하나 만든다. 대본은 비어 있다 — 에이전트가 쓴다.
  """
  def spawn_project(%Recipe{} = series, opts \\ []) do
    title = opts[:title] || "#{series.name} ##{series.created_count + 1}"

    attrs = %{
      "title" => title,
      "topic" => opts[:topic] || series.topic_brief,
      "target_sec" => series.target_sec,
      "aspect" => series.aspect,
      "style_slug" => series.style.slug,
      "domain_slug" => series.domain.slug,
      "voice_slug" => series.voice.slug,
      "output_folder" => series.output_folder,
      "pipeline" => series.pipeline,
      "language" => List.first(series.languages || ["ko"]) || "ko"
    }

    with {:ok, project} <- Projects.create_project(attrs),
         {:ok, project} <-
           project |> Ecto.Changeset.change(series_id: series.id) |> Repo.update() do
      {:ok, _} =
        update_counters(series, %{
          created_count: series.created_count + 1,
          last_run_at: DateTime.utc_now() |> DateTime.truncate(:second),
          next_run_at: if(series.active and series.interval_minutes > 0, do: in_minutes(series.interval_minutes)),
          last_error: ""
        })

      {:ok, project}
    end
  end

  defp update_counters(series, attrs) do
    series |> Ecto.Changeset.change(attrs) |> Repo.update()
  end

  @doc "아직 대본이 없는(=에이전트가 손 안 댄) 이 시리즈의 프로젝트 수."
  def pending_count(series_id) do
    Repo.one(
      from p in Project,
        where: p.series_id == ^series_id and p.status == "draft",
        select: count(p.id)
    )
  end

  @doc """
  지금 만들어야 할 시리즈를 처리한다. 러너가 1분마다 부른다.

  대기 중인 프로젝트가 `max_pending` 이상 쌓여 있으면 만들지 않는다 —
  에이전트가 대본을 안 쓰는 동안 빈 프로젝트가 무한히 쌓이는 걸 막는다.
  """
  def run_due(now \\ DateTime.utc_now()) do
    Repo.all(
      from s in Recipe,
        where: s.active and s.interval_minutes > 0 and not is_nil(s.next_run_at) and s.next_run_at <= ^now,
        preload: [:style, :domain, :voice]
    )
    |> Enum.map(&run_one/1)
  end

  defp run_one(series) do
    pending = pending_count(series.id)

    if pending >= series.max_pending do
      # 다음 시각은 미뤄둔다. 안 그러면 매 틱마다 다시 걸린다.
      {:ok, _} =
        update_counters(series, %{
          next_run_at: in_minutes(series.interval_minutes),
          last_error: "대기 #{pending}건이 상한(#{series.max_pending})에 걸려 건너뜀"
        })

      {:skipped, series.id, pending}
    else
      case spawn_project(series) do
        {:ok, project} ->
          Logger.info("시리즈 '#{series.name}' → 프로젝트 #{project.id} 생성")
          {:created, series.id, project.id}

        {:error, reason} ->
          message = inspect(reason)
          Logger.error("시리즈 '#{series.name}' 생성 실패: #{message}")

          {:ok, _} =
            update_counters(series, %{
              next_run_at: in_minutes(series.interval_minutes),
              last_error: String.slice(message, 0, 500)
            })

          {:failed, series.id, message}
      end
    end
  end
end

defmodule VideoCRM.Series.Runner do
  @moduledoc """
  1분마다 시리즈를 확인해 때가 된 것을 만든다.

  cron 이 아니라 앱 안에 두는 이유: 서버가 떠 있을 때만 돌아야 한다.
  서버가 죽어 있는 동안 밀린 것을 몰아서 만들면 몇 분 만에 하루치가 쏟아진다.
  """
  use GenServer
  require Logger

  @tick :timer.minutes(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    if enabled?() do
      try do
        VideoCRM.Series.run_due()
      rescue
        e -> Logger.error("시리즈 러너 오류: #{Exception.message(e)}")
      end
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :tick, @tick)

  # 테스트에서는 끈다 — 테스트 도중에 프로젝트가 생기면 안 된다.
  defp enabled?, do: Application.get_env(:video_crm, :series_runner, true)
end