defmodule VideoTool.Series.Recipe do
  @moduledoc """
  반복 제작 설정. 한 번 정해두면 간격마다 프로젝트가 하나씩 생긴다.

  **제작만 자동이고 발행은 아니다.** 만들어진 프로젝트는 대본이 비어 있는 상태로 대기하고,
  대본은 에이전트가 쓴다(서버에는 LLM 이 없다). 발행은 사람이 누를 때만 나간다.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Presets.{StylePreset, DomainPreset, Voice}

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
    # 이 시리즈로 만든 영상을 올릴 발행 채널. 비어 있으면 자동 발행하지 않는다.
    field :channel_slug, :string, default: ""
    # 이 시리즈로 만드는 프로젝트가 물려받을 자막 폰트.
    field :subtitle_font, :string, default: ""
    # 낭독 속도는 시리즈에도 열어두지만 기본은 0(보통)이다.
    # 길이가 안 맞는다고 여기를 올리지 않는다 — 대본을 고친다.
    field :voice_speech_rate, :float, default: 0.0

    field :interval_minutes, :integer, default: 0
    # 시각 예약. ["09:00", "21:00"] 처럼 로컬 시각. 채워져 있으면 interval_minutes 보다 우선한다 —
    # 둘을 함께 쓰면 언제 도는지 사람이 예측할 수 없다.
    field :run_times, {:array, :string}, default: []
    # 1=월 … 7=일. 비어 있으면 매일.
    field :run_days, {:array, :integer}, default: []
    # 켜면 서버가 대본이 채워진 프로젝트를 스스로 Flow 단계까지 민다.
    # 기본은 꺼둔다 — 켜는 순간 사람 없이 크레딧이 나간다.
    field :auto_advance, :boolean, default: false
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
             channel_slug
             interval_minutes active max_pending style_id domain_id voice_id
             subtitle_font voice_speech_rate run_times run_days auto_advance
             last_run_at next_run_at last_error created_count)a

  @doc "\"09:00\" → {9, 0}. 형식이 틀리면 nil."
  def parse_time(text) do
    with [h, m] <- String.split(String.trim(to_string(text)), ":"),
         {h, ""} <- Integer.parse(h),
         {m, ""} <- Integer.parse(m),
         true <- h in 0..23 and m in 0..59 do
      {h, m}
    else
      _ -> nil
    end
  end

  defp validate_times(changeset) do
    times = get_field(changeset, :run_times) || []
    bad = Enum.reject(times, &parse_time/1)

    if bad == [] do
      # 중복과 공백을 정리해 저장한다. 같은 시각이 두 번 있으면 두 번 돈다.
      cleaned = times |> Enum.map(&String.trim/1) |> Enum.uniq() |> Enum.sort()
      put_change(changeset, :run_times, cleaned)
    else
      add_error(changeset, :run_times, "시각은 HH:MM 형식으로 쓰세요 (잘못된 값: #{Enum.join(bad, ", ")})")
    end
  end

  defp validate_days(changeset) do
    days = get_field(changeset, :run_days) || []

    if Enum.all?(days, &(&1 in 1..7)) do
      put_change(changeset, :run_days, days |> Enum.uniq() |> Enum.sort())
    else
      add_error(changeset, :run_days, "요일은 1(월)~7(일) 이어야 합니다")
    end
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required([:name, :style_id, :domain_id, :voice_id])
    |> validate_inclusion(:aspect, ["16:9", "9:16"])
    |> validate_inclusion(:pipeline, VideoTool.Projects.Project.pipelines())
    |> validate_number(:target_sec, greater_than: 0)
    # 0 = 자동 생성 안 함. 1분 미만은 실수로 보고 막는다 — 분당 한 편은 만들 수 없다.
    |> validate_number(:interval_minutes, greater_than_or_equal_to: 0)
    |> validate_number(:max_pending, greater_than: 0, less_than_or_equal_to: 50)
    |> validate_times()
    |> validate_days()
    # 속도를 넓게 열어두면 결국 길이 맞추는 데 쓰게 된다. 빠르게 읽히면 설명이 아니라 광고가 된다.
    |> validate_number(:voice_speech_rate,
      greater_than_or_equal_to: -0.2,
      less_than_or_equal_to: 0.1,
      message: "낭독 속도는 -0.2~0.1 안에서만. 길이가 안 맞으면 속도가 아니라 대본을 고칩니다"
    )
    |> assoc_constraint(:style)
    |> assoc_constraint(:domain)
    |> assoc_constraint(:voice)
  end
end

defmodule VideoTool.Series do
  @moduledoc "반복 제작 설정 관리와 실행."

  import Ecto.Query
  require Logger

  alias VideoTool.{Projects, Repo}
  alias VideoTool.Projects.Project
  alias VideoTool.Series.Recipe

  def list do
    Repo.all(from s in Recipe, order_by: [desc: s.updated_at], preload: [:style, :domain, :voice])
  end

  def get(id) do
    case Repo.get(Recipe, id) |> Repo.preload([:style, :domain, :voice]) do
      nil -> {:error, "시리즈 #{id} 을(를) 찾을 수 없습니다"}
      s -> {:ok, s}
    end
  end

  @colors ~w(#ef4444 #f97316 #f59e0b #84cc16 #10b981 #14b8a6
             #06b6d4 #3b82f6 #6366f1 #8b5cf6 #d946ef #ec4899)

  @doc """
  시리즈 id → 색. 프로젝트 목록도 이 표를 써서 같은 시리즈면 같은 색으로 보인다.

  해시가 아니라 만든 순서로 돌려쓴다 — 해시면 시리즈 다섯 개만 돼도
  절반 넘는 확률로 두 시리즈가 같은 색을 받아 색으로 구분하는 의미가 없어진다.
  색은 12개라 13번째부터 돌아온다.
  """
  def color_map(recipes \\ list()) do
    recipes
    |> Enum.sort_by(& &1.id)
    |> Enum.with_index()
    |> Map.new(fn {s, i} -> {s.id, Enum.at(@colors, rem(i, length(@colors)))} end)
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

  # 일정에 영향을 주는 값이 바뀌면 다음 실행 시각을 다시 잡는다.
  # 간격만 보면 시각 예약을 바꿔도 반영이 안 된다 — 저장했는데 안 바뀌는 게 제일 헷갈린다.
  @schedule_fields [:active, :interval_minutes, :run_times, :run_days]

  defp put_next_run(changeset) do
    if Enum.any?(@schedule_fields, &Ecto.Changeset.changed?(changeset, &1)) do
      draft = Ecto.Changeset.apply_changes(changeset)
      Ecto.Changeset.put_change(changeset, :next_run_at, next_run(draft))
    else
      changeset
    end
  end

  defp in_minutes(minutes) do
    DateTime.utc_now() |> DateTime.add(minutes * 60, :second) |> DateTime.truncate(:second)
  end

  @doc """
  대본이 채워진 프로젝트를 한 건만 다음 단계로 민다.

  한 번에 하나만 미는 이유: Flow 는 브라우저 하나를 쓴다. 둘을 동시에 밀면 같은 창을
  서로 뺏는다 — 실제로 두 세션이 같은 Chrome 을 조종해 엉킨 적이 있다.

  `auto_advance` 를 켠 시리즈의 프로젝트만 민다. 켜는 순간 사람 없이 크레딧이 나가므로
  기본은 꺼져 있다.
  """
  def advance_one do
    with nil <- running_flow_job(),
         project when not is_nil(project) <- next_advanceable() do
      VideoTool.Pipeline.next(project)
    else
      _ -> :idle
    end
  end

  # Flow 작업이 이미 돌고 있으면 건드리지 않는다.
  defp running_flow_job do
    Repo.one(
      from j in VideoTool.Jobs.GenerationJob,
        where: j.provider == "flow" and j.status == "running",
        limit: 1
    )
  end

  # 자동 전진을 켠 시리즈에 속하고, 에이전트 몫(대본·장면·허용수치)이 이미 끝난 것만.
  # 그게 안 끝났으면 서버가 할 수 있는 일이 없다 — 서버에는 LLM 이 없다.
  defp next_advanceable do
    from(p in VideoTool.Projects.Project,
      join: s in Recipe,
      on: s.id == p.series_id,
      where: s.auto_advance and p.pipeline == "flow_auto" and p.status == "scened",
      order_by: [asc: p.id],
      limit: 1,
      preload: [:style, :domain, :voice]
    )
    |> Repo.one()
  end

  @doc """
  다음에 돌 시각. 시각 예약이 있으면 그걸 쓰고, 없으면 간격으로 계산한다.

  둘 다 비어 있으면 `nil` — 자동으로 돌지 않는다는 뜻이다.
  시각은 **로컬 시각**으로 적는다. 사람이 "아침 9시" 라고 생각하지 UTC 로 생각하지 않는다.
  tzdata 를 들이지 않고 로컬과 UTC 의 차이를 재서 옮긴다 — 의존성 하나를 아낀다.
  """
  def next_run(%Recipe{} = series) do
    cond do
      not series.active -> nil
      series.run_times != [] -> next_scheduled(series)
      series.interval_minutes > 0 -> in_minutes(series.interval_minutes)
      true -> nil
    end
  end

  defp next_scheduled(series) do
    offset = local_offset_seconds()
    now_local = DateTime.utc_now() |> DateTime.add(offset, :second) |> DateTime.truncate(:second)
    times = series.run_times |> Enum.map(&parse_time/1) |> Enum.reject(&is_nil/1) |> Enum.sort()

    if times == [] do
      nil
    else
      # 오늘부터 일주일 안에서 가장 빠른 다음 차례를 찾는다.
      0..7
      |> Enum.flat_map(fn add_days ->
        date = Date.add(DateTime.to_date(now_local), add_days)

        if allowed_day?(series, date) do
          Enum.map(times, fn {h, m} ->
            {:ok, naive} = NaiveDateTime.new(date, Time.new!(h, m, 0))
            naive
          end)
        else
          []
        end
      end)
      |> Enum.map(&DateTime.from_naive!(&1, "Etc/UTC"))
      |> Enum.filter(&(DateTime.compare(&1, now_local) == :gt))
      |> Enum.min_by(&DateTime.to_unix/1, fn -> nil end)
      |> case do
        nil -> nil
        local -> local |> DateTime.add(-offset, :second) |> DateTime.truncate(:second)
      end
    end
  end

  # 요일이 비어 있으면 매일. 1=월 … 7=일 (Date.day_of_week 와 같은 규칙).
  defp allowed_day?(%{run_days: []}, _date), do: true
  defp allowed_day?(%{run_days: days}, date), do: Date.day_of_week(date) in days

  defp local_offset_seconds do
    NaiveDateTime.diff(NaiveDateTime.local_now(), NaiveDateTime.utc_now())
    |> then(&(round(&1 / 60) * 60))
  end

  defp parse_time(text), do: Recipe.parse_time(text)



  @task_name "videoTool-agent"

  @doc """
  헤드리스 에이전트를 지금 깨운다.

  서버는 MCP 클라이언트에게 먼저 말을 걸 수 없다 — MCP 는 클라이언트가 묻고 서버가
  답하는 한 방향이라 "영상 하나 만들어라" 를 데스크톱 앱으로 밀 방법이 없다.
  그래서 예약 작업(`run-agent.ps1`)을 대신 찔러 `claude --print` 를 띄운다.

  겹쳐 도는 것은 스크립트의 잠금 파일이 막는다. 여기서 또 막을 필요는 없다.
  """
  def kick_agent do
    case System.cmd("powershell", ["-NoProfile", "-Command", "Start-ScheduledTask -TaskName '#{@task_name}'"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {out, code} ->
        Logger.warning("에이전트를 깨우지 못했습니다 (#{code}): #{String.trim(out)}")
        {:error, "예약 작업 '#{@task_name}' 이(가) 없거나 실행되지 않았습니다"}
    end
  rescue
    e in ErlangError -> {:error, "powershell 실행 실패: #{inspect(e.original)}"}
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
      "language" => List.first(series.languages || ["ko"]) || "ko",
      # 자막 폰트를 물려준다. 안 물려주면 편마다 글자가 달라진다.
      "subtitle_font" => series.subtitle_font || ""
    }

    with {:ok, project} <- Projects.create_project(attrs),
         {:ok, project} <-
           project |> Ecto.Changeset.change(series_id: series.id) |> Repo.update() do
      {:ok, _} =
        update_counters(series, %{
          created_count: series.created_count + 1,
          last_run_at: DateTime.utc_now() |> DateTime.truncate(:second),
          next_run_at: next_run(series),
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
        # next_run_at 이 곧 약속이다. 간격이든 시각 예약이든 여기서 걸러지면 안 된다 —
        # 예전엔 interval_minutes > 0 을 걸어서 시각 예약만 쓰는 시리즈가 영영 안 돌았다.
        where: s.active and not is_nil(s.next_run_at) and s.next_run_at <= ^now,
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
          next_run_at: next_run(series),
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
              next_run_at: next_run(series),
              last_error: String.slice(message, 0, 500)
            })

          {:failed, series.id, message}
      end
    end
  end
end

defmodule VideoTool.Series.Runner do
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
    # 서버가 죽을 때 돌던 Flow 작업은 Task 와 함께 사라진다. 행만 'running' 으로 남으면
    # 자동 전진이 "이미 돌고 있다" 로 보고 영영 멈춘다 — 뜰 때 한 번 치운다.
    #
    # **웹을 실제로 띄울 때만 치운다.** `mix run priv/repo/xxx.exs` 같은 스크립트도
    # 앱을 부팅하므로 이 init 이 돌아간다. 그때 치우면 **서버에서 멀쩡히 돌고 있는**
    # Flow 작업까지 실패로 찍어 버린다 — 실측: 시리즈 설정을 바꾸는 스크립트 한 줄이
    # 에이전트가 진행 중이던 VIDEO 작업을 죽였다.
    if enabled?() and Phoenix.Endpoint.server?(:video_tool, VideoToolWeb.Endpoint) do
      case VideoTool.Jobs.sweep_orphaned_flow_jobs() do
        0 -> :ok
        n -> Logger.info("재시작으로 끊긴 Flow 작업 #{n}건을 실패로 정리했습니다")
      end
    end

    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    if enabled?() do
      try do
        VideoTool.Series.run_due()
        # 프로젝트를 만들기만 하고 두면 대기만 쌓인다. 밀 수 있는 건 여기서 민다.
        VideoTool.Series.advance_one()
      rescue
        e -> Logger.error("시리즈 러너 오류: #{Exception.message(e)}")
      end
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :tick, @tick)

  # 테스트에서는 끈다 — 테스트 도중에 프로젝트가 생기면 안 된다.
  defp enabled?, do: Application.get_env(:video_tool, :series_runner, true)
end