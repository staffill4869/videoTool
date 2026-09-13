defmodule VideoToolWeb.ApiController do
  @moduledoc """
  REST 창구. MCP 로 할 수 있는 일을 HTTP 로도 할 수 있게 열어둔다 —
  MCP 를 못 쓰는 클라이언트도 있고, curl 로 한 줄 확인하는 게 빠를 때가 있다.

  툴 하나하나를 따로 구현하지 않는다. `POST /api/tools/:name` 이 MCP 디스패치로 그대로 넘긴다 —
  두 벌로 구현하면 한쪽만 고쳐지는 날이 온다.
  """
  use VideoToolWeb, :controller

  alias VideoTool.{Insights, MCP, Presets, Projects, Prompt, Repo, Series, Work}

  action_fallback VideoToolWeb.FallbackController

  # ── 작업 큐 ─────────────────────────────────────────────────────

  def next_job(conn, _params) do
    {:ok, job} = Work.next_job()
    json(conn, %{ok: true, job: job})
  end

  def jobs(conn, params) do
    limit = to_int(params["limit"], 20)
    json(conn, %{ok: true, jobs: Work.pending_jobs(limit)})
  end

  def summary(conn, _params), do: json(conn, %{ok: true, summary: Work.summary()})

  # ── 프로젝트 ────────────────────────────────────────────────────

  def list_projects(conn, _params) do
    json(conn, %{ok: true, projects: Enum.map(Projects.list_projects(), &project_brief/1)})
  end

  def get_project(conn, %{"id" => id}) do
    with {:ok, project} <- Projects.get_project(id) do
      json(conn, %{ok: true, project: project_detail(project)})
    end
  end

  def create_project(conn, params) do
    with {:ok, project} <- Projects.create_project(params) do
      conn |> put_status(:created) |> json(%{ok: true, project_id: project.id, work_dir: project.work_dir})
    end
  end

  def update_project(conn, %{"id" => id} = params) do
    with {:ok, project} <- Projects.get_project(id),
         {:ok, updated} <- Projects.update_project(project, Map.drop(params, ["id"])) do
      json(conn, %{ok: true, project: project_brief(updated)})
    end
  end

  def delete_project(conn, %{"id" => id}) do
    with {:ok, project} <- Projects.get_project(id),
         {:ok, _} <- Projects.delete_project(project) do
      # 작업 폴더는 지우지 않는다 — 생성물이 들어 있고, 지우면 되돌릴 수 없다.
      json(conn, %{ok: true, deleted: project.id, work_dir_kept: project.work_dir})
    end
  end

  @doc """
  같은 영상의 다른 언어판. CLEAN 이미지는 다시 만들지 않고 원본 것을 그대로 쓴다.
  """
  def create_variant(conn, %{"id" => id} = params) do
    with {:ok, source} <- Projects.get_project(id),
         {:ok, result} <-
           Projects.create_language_variant(source, params["language"] || "en",
             voice_slug: params["voice_slug"],
             title: params["title"]
           ) do
      conn
      |> put_status(:created)
      |> json(%{
        ok: true,
        project_id: result.project.id,
        language: result.project.language,
        scenes: result.scenes,
        clean_reused: result.clean_reused,
        note: "CLEAN 이미지 #{result.clean_reused}장을 원본과 공유합니다. INFO 와 나레이션만 새로 만듭니다."
      })
    end
  end

  def list_variants(conn, %{"id" => id}) do
    json(conn, %{ok: true, variants: Enum.map(Projects.variants(id), &project_brief/1)})
  end

  def languages(conn, _params) do
    json(conn, %{ok: true, languages: Projects.language_names()})
  end

  # ── 프로젝트별 프롬프트 ─────────────────────────────────────────

  def get_prompt(conn, %{"id" => id, "stage" => stage}) do
    with {:ok, project} <- Projects.get_project(id),
         {:ok, body} <- Prompt.body_for(project, stage),
         {:ok, text} <- Prompt.render(project, stage),
         {:ok, missing} <- Prompt.missing_variables(project, stage) do
      json(conn, %{
        ok: true,
        stage: stage,
        overridden: Prompt.overridden?(project, stage),
        body: body,
        rendered: text,
        chars: String.length(text),
        variables: Prompt.variables(project),
        missing_variables: missing
      })
    end
  end

  def put_prompt(conn, %{"id" => id, "stage" => stage} = params) do
    with {:ok, project} <- Projects.get_project(id),
         {:ok, updated} <- Projects.set_prompt_override(project, stage, params["body"]) do
      json(conn, %{ok: true, stage: stage, overridden: Prompt.overridden?(updated, stage)})
    end
  end

  def delete_prompt(conn, %{"id" => id, "stage" => stage}) do
    with {:ok, project} <- Projects.get_project(id),
         {:ok, _} <- Projects.set_prompt_override(project, stage, nil) do
      json(conn, %{ok: true, stage: stage, overridden: false, note: "공용 템플릿으로 돌아갑니다"})
    end
  end

  # ── 시리즈 ──────────────────────────────────────────────────────

  def list_series(conn, _params) do
    json(conn, %{ok: true, series: Enum.map(Series.list(), &series_brief/1)})
  end

  def get_series(conn, %{"id" => id}) do
    with {:ok, series} <- Series.get(id) do
      json(conn, %{ok: true, series: series_detail(series)})
    end
  end

  def create_series(conn, params) do
    with {:ok, attrs} <- resolve_preset_slugs(params),
         {:ok, series} <- Series.create(attrs) do
      conn |> put_status(:created) |> json(%{ok: true, series_id: series.id})
    end
  end

  def update_series(conn, %{"id" => id} = params) do
    with {:ok, series} <- Series.get(id),
         {:ok, attrs} <- resolve_preset_slugs(Map.drop(params, ["id"]), series),
         {:ok, updated} <- Series.update(series, attrs) do
      json(conn, %{ok: true, series: series_brief(updated)})
    end
  end

  def delete_series(conn, %{"id" => id}) do
    with {:ok, series} <- Series.get(id),
         {:ok, _} <- Series.delete(series) do
      json(conn, %{ok: true, deleted: series.id, note: "만들어진 프로젝트는 남습니다"})
    end
  end

  def run_series(conn, %{"id" => id}) do
    with {:ok, series} <- Series.get(id),
         {:ok, project} <- Series.spawn_project(series, title: conn.params["title"], topic: conn.params["topic"]) do
      conn |> put_status(:created) |> json(%{ok: true, project_id: project.id, title: project.title})
    end
  end

  # ── 성과 ────────────────────────────────────────────────────────

  def dashboard(conn, _params), do: json(conn, %{ok: true, dashboard: Insights.dashboard()})
  # rows 는 Insights 가 평범한 맵으로 눕혀 준다 (Ecto 구조체는 JSON 인코더가 없다).

  def collect_metrics(conn, _params) do
    with {:ok, result} <- Insights.collect_youtube() do
      json(conn, Map.merge(%{ok: true}, result))
    end
  end

  def record_metrics(conn, %{"id" => id} = params) do
    attrs = Map.take(params, ~w(views likes comments shares note))

    with {:ok, metric} <- Insights.record(String.to_integer(id), attrs) do
      conn |> put_status(:created) |> json(%{ok: true, metric_id: metric.id})
    end
  end

  def metric_history(conn, %{"id" => id}) do
    rows =
      id
      |> String.to_integer()
      |> Insights.history()
      |> Enum.map(&Map.take(&1, [:collected_at, :views, :likes, :comments, :shares, :source]))

    json(conn, %{ok: true, history: rows})
  end

  # ── MCP 툴 통로 ─────────────────────────────────────────────────

  def tools(conn, _params), do: json(conn, %{ok: true, tools: MCP.tools()})

  def call_tool(conn, %{"name" => name} = params) do
    result = MCP.call(name, Map.drop(params, ["name"]))
    status = if result[:ok] == false, do: :unprocessable_entity, else: :ok
    conn |> put_status(status) |> json(result)
  end

  # ── 표현 ────────────────────────────────────────────────────────

  defp project_brief(p) do
    %{
      id: p.id,
      title: p.title,
      status: p.status,
      aspect: p.aspect,
      target_sec: p.target_sec,
      pipeline: p.pipeline,
      language: p.language,
      variant_of_id: p.variant_of_id,
      series_id: p.series_id,
      subtitle_font: p.subtitle_font,
      updated_at: p.updated_at
    }
  end

  defp project_detail(p) do
    p
    |> project_brief()
    |> Map.merge(%{
      topic: p.topic,
      work_dir: p.work_dir,
      output_folder: p.output_folder,
      style: p.style.slug,
      domain: p.domain.slug,
      voice: p.voice.slug,
      variables: Prompt.variables(p),
      prompt_overrides: Map.keys(p.prompt_overrides || %{}),
      scenes: length(Projects.scenes(p.id))
    })
  end

  defp series_brief(s) do
    %{
      id: s.id,
      name: s.name,
      active: s.active,
      interval_minutes: s.interval_minutes,
      max_pending: s.max_pending,
      created_count: s.created_count,
      next_run_at: s.next_run_at,
      last_error: s.last_error,
      style: s.style.slug,
      domain: s.domain.slug,
      voice: s.voice.slug
    }
  end

  defp series_detail(s) do
    s
    |> series_brief()
    |> Map.merge(%{
      topic_brief: s.topic_brief,
      standing_prompt: s.standing_prompt,
      aspect: s.aspect,
      target_sec: s.target_sec,
      pipeline: s.pipeline,
      output_folder: s.output_folder,
      pending: Series.pending_count(s.id)
    })
  end

  # slug 로 받아 id 로 바꾼다. API 에서 내부 id 를 알 필요가 없게 한다.
  defp resolve_preset_slugs(params, fallback \\ nil) do
    with {:ok, style_id} <- resolve(params["style_slug"], &Presets.fetch_style/1, fallback && fallback.style_id),
         {:ok, domain_id} <- resolve(params["domain_slug"], &Presets.fetch_domain/1, fallback && fallback.domain_id),
         {:ok, voice_id} <- resolve(params["voice_slug"], &Presets.fetch_voice/1, fallback && fallback.voice_id) do
      {:ok,
       params
       |> Map.drop(["style_slug", "domain_slug", "voice_slug"])
       |> Map.merge(%{"style_id" => style_id, "domain_id" => domain_id, "voice_id" => voice_id})}
    end
  end

  defp resolve(nil, _fetch, fallback), do: {:ok, fallback}

  defp resolve(slug, fetch, _fallback) do
    with {:ok, row} <- fetch.(slug), do: {:ok, row.id}
  end

  defp to_int(nil, default), do: default

  defp to_int(value, default) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> default
    end
  end

  _ = Repo
end