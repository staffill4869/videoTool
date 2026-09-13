defmodule VideoTool.Jobs.GenerationJob do
  @moduledoc "외부 AI 호출 이력. Flow 는 API 가 없어 크레딧을 사용자가 수동 입력한다."
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Media.Asset
  alias VideoTool.Projects.Project

  schema "generation_jobs" do
    field :provider, :string
    field :model, :string, default: ""
    field :external_job_id, :string, default: ""
    field :status, :string, default: "pending"
    field :result_url, :string, default: ""
    field :credits, :decimal, default: Decimal.new(0)
    field :error, :string, default: ""
    field :requested_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :project, Project
    belongs_to :asset, Asset

    timestamps(type: :utc_datetime)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(project_id asset_id provider model external_job_id status
                      result_url credits error requested_at finished_at)a)
    |> validate_required([:project_id, :provider, :requested_at])
  end
end

defmodule VideoTool.Jobs.IngestJob do
  @moduledoc "Downloads 감시로 들어온 Flow zip 처리 이력."
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Projects.Project

  @methods ~w(ocr phash filename)

  schema "ingest_jobs" do
    field :watched_path, :string, default: ""
    field :detected_file, :string, default: ""
    field :file_mtime, :utc_datetime
    field :extracted_count, :integer, default: 0
    field :mapped_count, :integer, default: 0
    field :method, :string, default: "phash"
    field :status, :string, default: "pending"
    field :log, :string, default: ""

    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  def methods, do: @methods

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(project_id watched_path detected_file file_mtime extracted_count
                      mapped_count method status log)a)
    |> validate_required([:project_id])
    |> validate_inclusion(:method, @methods)
  end
end

defmodule VideoTool.Jobs.Validation do
  @moduledoc "단계별 검증 결과. passed 여야 next/1 이 다음 단계로 넘어간다."
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Projects.Project

  @stages ~w(clean info clips final)

  schema "validations" do
    field :stage, :string
    field :passed, :boolean, default: false
    field :checks, :map, default: %{}
    # [%{"scene_no" => 12, "issue" => "허용 외 '30일'"}, ...]
    field :problems, VideoTool.JSONTerm, default: []

    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  def stages, do: @stages

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(project_id stage passed checks problems)a)
    |> validate_required([:project_id, :stage])
    |> validate_inclusion(:stage, @stages)
  end
end

defmodule VideoTool.Jobs do
  @moduledoc "작업 이력 조회·기록."

  import Ecto.Query
  alias VideoTool.Repo
  alias VideoTool.Jobs.{GenerationJob, IngestJob, Validation}

  def record_generation(attrs) do
    attrs = Map.put_new(attrs, :requested_at, DateTime.utc_now() |> DateTime.truncate(:second))
    %GenerationJob{} |> GenerationJob.changeset(attrs) |> Repo.insert()
  end

  @doc "Flow 는 API 가 없어 사용자가 화면에서 읽은 크레딧을 넣는다."
  def report_flow_credits(project_id, credits) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    record_generation(%{
      project_id: project_id,
      provider: "flow",
      model: "manual-report",
      status: "done",
      credits: credits,
      requested_at: now,
      finished_at: now
    })
  end

  def finish_generation(%GenerationJob{} = job, status, error) do
    job
    |> GenerationJob.changeset(%{
      status: status,
      error: error,
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  @doc """
  이 프로젝트에서 이 단계를 몇 번 돌렸나. 재시도 한도를 재는 데 쓴다.

  한도가 없으면 러너가 1분마다 같은 프롬프트를 다시 넣는다 — 크레딧만 태우고
  결과는 같다. 몇 번 해보고 안 되면 있는 것으로 다음 단계로 가는 편이 낫다.
  """
  def count_generations(project_id, stage) do
    Repo.one(
      from j in GenerationJob,
        where: j.project_id == ^project_id and j.provider == "flow" and j.model == ^stage,
        select: count(j.id)
    ) || 0
  end

  @doc "이 프로젝트에서 지금 돌고 있는 Flow 자동 조종 작업. 있으면 next/1 은 기다리라고 답한다."
  def running_flow_job(project_id) do
    Repo.one(
      from j in GenerationJob,
        where: j.project_id == ^project_id and j.provider == "flow" and j.status == "running",
        order_by: [desc: j.id],
        limit: 1
    )
  end

  @doc "이 프로젝트의 가장 최근 Flow 작업. 상태가 뭐든 최신 것 하나."
  def latest_flow_job(project_id) do
    Repo.one(
      from j in GenerationJob,
        where: j.project_id == ^project_id and j.provider == "flow",
        order_by: [desc: j.id],
        limit: 1
    )
  end

  @doc """
  서버가 뜰 때, 돌던 것으로 남아 있는 Flow 작업을 전부 실패로 정리한다.

  그 작업들을 돌리던 Task 는 VM 과 함께 죽었으므로 되살아날 방법이 없다.
  치우지 않으면 "이미 돌고 있다" 로 보여 자동 전진이 영영 멈춘다 — 실제로 그렇게 막혔다.
  """
  def sweep_orphaned_flow_jobs do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(j in GenerationJob, where: j.provider == "flow" and j.status == "running"),
        set: [status: "failed", error: "서버가 재시작되어 중단됨", finished_at: now]
      )

    count
  end

  @doc "마지막으로 실패한 Flow 작업 (사용자에게 왜 멈췄는지 알려주기 위해)."
  def last_failed_flow_job(project_id) do
    Repo.one(
      from j in GenerationJob,
        where: j.project_id == ^project_id and j.provider == "flow" and j.status == "failed",
        order_by: [desc: j.id],
        limit: 1
    )
  end

  def credits_by_provider(project_id) do
    from(j in GenerationJob,
      where: j.project_id == ^project_id,
      group_by: j.provider,
      select: {j.provider, sum(j.credits)}
    )
    |> Repo.all()
    |> Map.new(fn {p, c} -> {p, Decimal.to_float(c || Decimal.new(0))} end)
  end

  def create_ingest_job(attrs), do: %IngestJob{} |> IngestJob.changeset(attrs) |> Repo.insert()

  def update_ingest_job(%IngestJob{} = job, attrs),
    do: job |> IngestJob.changeset(attrs) |> Repo.update()

  @doc "이 프로젝트가 마지막으로 가져온 zip. 같은 zip 을 두 번 가져오지 않기 위한 기준."
  def latest_ingest_job(project_id) do
    Repo.one(
      from j in IngestJob,
        where: j.project_id == ^project_id,
        order_by: [desc: j.id],
        limit: 1
    )
  end

  def record_validation(project_id, stage, passed, checks, problems) do
    %Validation{}
    |> Validation.changeset(%{
      project_id: project_id,
      stage: stage,
      passed: passed,
      checks: checks,
      problems: problems
    })
    |> Repo.insert()
  end

  def latest_validation(project_id, stage) do
    Repo.one(
      from v in Validation,
        where: v.project_id == ^project_id and v.stage == ^stage,
        order_by: [desc: v.id],
        limit: 1
    )
  end

  def latest_validation(project_id) do
    Repo.one(
      from v in Validation,
        where: v.project_id == ^project_id,
        order_by: [desc: v.id],
        limit: 1
    )
  end
end