defmodule VideoTool.Progress do
  @moduledoc """
  화면이 쓰는 진행 상태. 한 군데서만 만든다.

  왜 필요한가: 같은 사실을 화면마다 다르게 불렀다 — 목록은 `status` 글자를 그대로 뱉고,
  에이전트 화면은 `CLEAN 대기 (3/8)` 이라 쓰고, 성과 화면은 아예 몰랐다.
  그래서 "지금 어디까지 왔나" 를 화면을 옮겨 다니며 머리로 합쳐야 했다.

  여기서 정하는 것은 셋이다:

    * **눈금 여덟 칸** — `status` 아홉 가지는 "완료된 칸 수" 와 일대일로 맞는다
      (`draft` 0칸 … `done` 8칸). 그래서 눈금은 상태를 다시 해석하지 않는다.
    * **누구 차례인가** — 서버·에이전트·Flow·사람. 이게 가장 안 보이던 값이다.
    * **사람 차례(`:gate`)** — DB 에는 없는 상태다. `clean_done`(눈 검수)과
      `assembled`(유튜브 동의)는 자동화가 아무리 돌아도 넘어가지 않는데,
      화면에서는 그냥 "대기" 로 보여서 몇 시간씩 방치됐다.
  """

  import Ecto.Query

  alias VideoTool.Jobs.GenerationJob
  alias VideoTool.Media.Asset
  alias VideoTool.Projects.{Project, Scene}
  alias VideoTool.{Repo, Series}

  @steps ~w(대본 장면 CLEAN INFO 영상 소리 합성 발행)

  # status → 끝난 칸 수. Projects 의 @statuses 순서와 같다.
  @ticks %{
    "draft" => 0,
    "scripted" => 1,
    "scened" => 2,
    "clean_done" => 3,
    "info_done" => 4,
    "clips_done" => 5,
    "narrated" => 6,
    "assembled" => 7,
    "done" => 8
  }

  # 사람이 손대야만 넘어가는 자리.
  @gates ~w(clean_done assembled)

  def steps, do: @steps

  def ticks(status), do: Map.get(@ticks, status, 0)

  @doc "사람을 기다리는 프로젝트 수. 메뉴의 배지가 이 값이다."
  def attention_count do
    Repo.one(from p in Project, where: p.status in @gates, select: count(p.id)) || 0
  end

  @doc """
  프로젝트마다 한 줄. 최근에 손댄 것부터.

  프로젝트 수만큼 질의하지 않는다 — 장면 수·자산 수·Flow 작업을 각각 한 번에 모아
  메모리에서 붙인다. 목록 화면이 프로젝트마다 두 번씩 질의하던 것을 여기서 없앴다.
  """
  def rows do
    projects = Repo.all(from p in Project, order_by: [desc: p.updated_at], preload: [:voice])
    ids = Enum.map(projects, & &1.id)

    scenes = scene_counts(ids)
    mapped = mapped_counts(ids)
    jobs = latest_flow_jobs(ids)
    colors = Series.color_map()

    Enum.map(projects, &row(&1, scenes, mapped, jobs, colors))
  end

  @doc "한 프로젝트만. 상세 화면이 쓴다."
  def row(project) do
    ids = [project.id]

    row(project, scene_counts(ids), mapped_counts(ids), latest_flow_jobs(ids), Series.color_map())
  end

  defp row(p, scenes, mapped, jobs, colors) do
    total = Map.get(scenes, p.id, 0)
    counts = Map.get(mapped, p.id, %{})
    job = Map.get(jobs, p.id)
    ticks = ticks(p.status)
    kind = kind(p.status, job)

    %{
      id: p.id,
      title: p.title,
      status: p.status,
      aspect: p.aspect,
      voice: p.voice && p.voice.display_name,
      series_id: p.series_id,
      color: Map.get(colors, p.series_id, "transparent"),
      scenes: total,
      clean: Map.get(counts, "clean", 0),
      info: Map.get(counts, "info", 0),
      clip: Map.get(counts, "clip", 0),
      ticks: ticks,
      kind: kind,
      steps: step_states(ticks, kind),
      owner: owner(p.status, kind, job),
      now: now(p.status, kind, job, counts, total),
      since: since(kind, job, p.updated_at)
    }
  end

  # ── 눈금 ──────────────────────────────────────────────────────

  defp step_states(ticks, kind) do
    here =
      case kind do
        :running -> :running
        :gate -> :gate
        :blocked -> :blocked
        _ -> :wait
      end

    @steps
    |> Enum.with_index()
    |> Enum.map(fn {name, i} ->
      state =
        cond do
          i < ticks -> :done
          i == ticks -> here
          true -> :wait
        end

      %{name: name, state: state}
    end)
  end

  # ── 무슨 상태인가 ────────────────────────────────────────────
  # Flow 작업 행이 먼저다. 서버가 죽어 `running` 이 남은 경우는 부팅 때 `failed` 로
  # 정리되므로, 여기서는 행을 그대로 믿어도 된다.

  defp kind("done", _job), do: :done

  # 도는 중이 사람 차례보다 먼저다 — `clean_done` 인 채로 INFO 가 돌고 있을 수 있다.
  defp kind(_status, %{status: "running"}), do: :running

  # 사람 차례가 묵은 실패 기록보다 먼저다 — 여기까지 왔다면 그 단계는 이미 지나갔다.
  defp kind(status, _job) when status in @gates, do: :gate
  defp kind(_status, %{status: "failed"}), do: :blocked
  defp kind(_status, _job), do: :queued

  # ── 누구 차례인가 ────────────────────────────────────────────

  defp owner(_status, :gate, _job), do: "사람"
  defp owner(_status, :done, _job), do: "끝"
  defp owner(_status, :blocked, _job), do: "서버"
  defp owner(_status, :running, _job), do: "Flow"
  defp owner(status, _kind, _job) when status in ~w(draft scripted clips_done), do: "에이전트"
  defp owner(status, _kind, _job) when status in ~w(scened info_done), do: "Flow"
  defp owner(_status, _kind, _job), do: "서버"

  # ── 한 줄로 읽는 지금 ────────────────────────────────────────

  defp now(_status, :done, _job, _counts, _total), do: "발행됨"

  defp now(_status, :blocked, job, _counts, _total),
    do: "#{stage_ko(job && job.model)} 작업 실패 · 재시도 필요"

  defp now("clean_done", :gate, _job, _counts, total),
    do: "CLEAN #{total}장 눈 검수 대기"

  defp now("assembled", :gate, _job, _counts, _total), do: "발행 대기"

  defp now(_status, :running, job, counts, total) do
    stage = job && job.model
    have = Map.get(counts, harvest_kind(stage), 0)

    "#{stage_ko(stage)} 생성 중 (#{have}/#{total})"
  end

  defp now(status, _kind, _job, _counts, _total) do
    case status do
      "draft" -> "대본 대기"
      "scripted" -> "장면 나누기 대기"
      "scened" -> "CLEAN 대기"
      "info_done" -> "영상 대기"
      "clips_done" -> "나레이션 대기"
      "narrated" -> "합성 대기"
      other -> other
    end
  end

  defp stage_ko("clean"), do: "CLEAN"
  defp stage_ko("info"), do: "INFO"
  defp stage_ko("video"), do: "영상"
  defp stage_ko(nil), do: "Flow"
  defp stage_ko(other), do: other

  defp harvest_kind("clean"), do: "clean"
  defp harvest_kind("info"), do: "info"
  defp harvest_kind("video"), do: "clip"
  defp harvest_kind(_), do: "clean"

  # ── 얼마나 됐나 ──────────────────────────────────────────────
  # 도는 중·막힘이면 작업이 시작된 때부터, 아니면 마지막으로 손댄 때부터 잰다.

  defp since(kind, %{requested_at: at}, _updated)
       when kind in [:running, :blocked] and not is_nil(at),
       do: elapsed(at)

  defp since(_kind, _job, updated), do: elapsed(updated)

  defp elapsed(%DateTime{} = at),
    do: at |> DateTime.diff(DateTime.utc_now()) |> abs() |> humanize()

  defp elapsed(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> elapsed()

  defp elapsed(_), do: nil

  defp humanize(sec) when sec < 60, do: "방금"
  defp humanize(sec) when sec < 3600, do: "#{div(sec, 60)}분째"
  defp humanize(sec) when sec < 86_400, do: "#{div(sec, 3600)}시간째"
  defp humanize(sec), do: "#{div(sec, 86_400)}일째"

  # ── 한 번에 모으는 것들 ──────────────────────────────────────

  defp scene_counts([]), do: %{}

  defp scene_counts(ids) do
    Repo.all(
      from s in Scene,
        where: s.project_id in ^ids,
        group_by: s.project_id,
        select: {s.project_id, count(s.id)}
    )
    |> Map.new()
  end

  defp mapped_counts([]), do: %{}

  defp mapped_counts(ids) do
    Repo.all(
      from a in Asset,
        where: a.project_id in ^ids and not is_nil(a.scene_id),
        group_by: [a.project_id, a.kind],
        select: {a.project_id, a.kind, count(a.scene_id, :distinct)}
    )
    |> Enum.group_by(&elem(&1, 0), fn {_id, kind, n} -> {kind, n} end)
    |> Map.new(fn {id, pairs} -> {id, Map.new(pairs)} end)
  end

  defp latest_flow_jobs([]), do: %{}

  defp latest_flow_jobs(ids) do
    Repo.all(
      from j in GenerationJob,
        where: j.provider == "flow" and j.project_id in ^ids,
        distinct: j.project_id,
        order_by: [asc: j.project_id, desc: j.id]
    )
    |> Map.new(&{&1.project_id, &1})
  end
end
