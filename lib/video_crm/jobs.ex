defmodule VideoCRM.Jobs.GenerationJob do
  @moduledoc "외부 AI 호출 이력. Flow 는 API 가 없어 크레딧을 사용자가 수동 입력한다."
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoCRM.Media.Asset
  alias VideoCRM.Projects.Project

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

defmodule VideoCRM.Jobs.IngestJob do
  @moduledoc "Downloads 감시로 들어온 Flow zip 처리 이력."
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoCRM.Projects.Project

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

defmodule VideoCRM.Jobs.Validation do
  @moduledoc "단계별 검증 결과. passed 여야 next/1 이 다음 단계로 넘어간다."
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoCRM.Projects.Project

  @stages ~w(clean info clips final)

  schema "validations" do
    field :stage, :string
    field :passed, :boolean, default: false
    field :checks, :map, default: %{}
    # [%{"scene_no" => 12, "issue" => "허용 외 '30일'"}, ...]
    field :problems, VideoCRM.JSONTerm, default: []

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

defmodule VideoCRM.Jobs do
  @moduledoc "작업 이력 조회·기록."

  import Ecto.Query
  alias VideoCRM.Repo
  alias VideoCRM.Jobs.{GenerationJob, IngestJob, Validation}

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

  @doc "이 프로젝트에서 지금 돌고 있는 Flow 자동 조종 작업. 있으면 next/1 은 기다리라고 답한다."
  def running_flow_job(project_id) do
    Repo.one(
      from j in GenerationJob,
        where: j.project_id == ^project_id and j.provider == "flow" and j.status == "running",
        order_by: [desc: j.id],
        limit: 1
    )
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