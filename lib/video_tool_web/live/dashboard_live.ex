defmodule VideoToolWeb.DashboardLive do
  @moduledoc """
  성과 대시보드. 조회수·좋아요·댓글을 발행물마다 재고 합쳐서 본다.

  아직 플랫폼 API 로 긁어오지 않는다 (OAuth 가 붙어야 한다).
  그때까지는 사람이 화면을 보고 넣는다 — **집계·비교는 지금부터 된다.**
  자동 수집이 붙으면 같은 표에 source=api 로 쌓이고 화면은 그대로다.
  """
  use VideoToolWeb, :live_view

  alias VideoTool.{Insights, Media, Projects, Publishing, YouTube}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(registering: false) |> load()}
  end

  defp load(socket) do
    assign(socket,
      api_key_ready: YouTube.configured?(),
      data: Insights.dashboard(),
      publications: Insights.measurable_publications(),
      projects: Projects.list_projects(),
      channels: Publishing.list_channels()
    )
  end

  # 언제 쟀는지. 정확한 시각보다 "얼마나 묵었나" 가 판단에 쓰인다.
  defp when_measured(nil), do: "—"

  defp when_measured(at) do
    case DateTime.diff(DateTime.utc_now(), at, :minute) do
      m when m < 60 -> "#{m}분 전"
      m when m < 1440 -> "#{div(m, 60)}시간 전"
      m -> "#{div(m, 1440)}일 전"
    end
  end

  # ── 이벤트 ──────────────────────────────────────────────────────

  @impl true
  def handle_event("collect", _params, socket) do
    case Insights.collect_youtube() do
      {:ok, result} ->
        message =
          "유튜브에서 #{result.recorded}건 수집" <>
            if(result.missing != [], do: " · #{length(result.missing)}건은 비공개/삭제", else: "") <>
            if(result.no_video_id != [], do: " · #{length(result.no_video_id)}건은 URL 없음", else: "")

        {:noreply, socket |> put_flash(:info, message) |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("toggle_register", _params, socket) do
    {:noreply, assign(socket, registering: not socket.assigns.registering)}
  end

  def handle_event("register", params, socket) do
    with {:ok, project} <- Projects.get_project(params["project_id"]),
         {:ok, channel} <- Publishing.fetch_channel(params["channel_slug"]) do
      render = Media.latest_render(project.id, project.aspect)

      case Insights.register_published(project, channel, render, params) do
        {:ok, _} ->
          {:noreply,
           socket |> put_flash(:info, "등록했습니다. 이제 성과를 기록할 수 있습니다.") |> assign(registering: false) |> load()}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, inspect(changeset.errors))}
      end
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
    end
  end

  # ── 화면 ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:dashboard}>
      <.header>
        성과
        <:subtitle>
          발행물마다 가장 최근 측정치로 합산한다. 「유튜브에서 수집」 을 누르면 API 키로 긁어 온다 — 손으로 넣을 필요가 없다.
        </:subtitle>
        <:actions>
          <.button
            :if={@api_key_ready}
            phx-click="collect"
            class="btn-primary btn-sm"
          >
            유튜브에서 수집
          </.button>
          <.button phx-click="toggle_register" class="btn-sm">
            {(@registering && "닫기") || "올린 영상 등록"}
          </.button>
        </:actions>
      </.header>

      <div :if={not @api_key_ready} class="alert alert-info mt-4 text-sm">
        <div>
          <div class="font-semibold">자동 수집을 켜려면 API 키 하나만 있으면 됩니다</div>
          <div class="mt-1 opacity-80">
            조회수·좋아요·댓글은 공개 영상이면 <strong>OAuth 없이 API 키만으로</strong> 읽힙니다.
            업로드용 OAuth 를 기다릴 필요가 없습니다.
          </div>
          <ol class="mt-2 list-decimal pl-5">
            <li>console.cloud.google.com 에서 프로젝트 만들기</li>
            <li>API 및 서비스 → 라이브러리 → <strong>YouTube Data API v3</strong> 사용 설정</li>
            <li>사용자 인증 정보 → 만들기 → <strong>API 키</strong></li>
            <li>
              프로젝트 폴더의 <code class="font-mono">.env</code> 에
              <code class="font-mono">GOOGLE_API_KEY=키값</code> 넣고 서버 재시작
            </li>
          </ol>
          <div class="mt-1 opacity-70">
            <code class="font-mono">.env.example</code> 를 복사해서 쓰면 됩니다.
          </div>
        </div>
      </div>

      <div class="mt-4 grid grid-cols-2 gap-3 md:grid-cols-5">
        <.stat label="발행물" value={@data.totals.count} />
        <.stat label="조회수" value={@data.totals.views} />
        <.stat label="좋아요" value={@data.totals.likes} />
        <.stat label="댓글" value={@data.totals.comments} />
        <.stat label="공유" value={@data.totals.shares} />
      </div>

      <form :if={@registering} phx-submit="register" class="mt-4 card bg-base-200">
        <div class="card-body gap-3 p-4">
          <div class="font-semibold">이 시스템 밖에서 올린 영상 등록</div>
          <div class="text-xs opacity-70">
            발행 기능이 아직 없어서, 지금 올라간 영상은 전부 손으로 올린 것이다.
            등록해두면 성과를 여기서 함께 본다.
          </div>

          <div class="grid gap-3 md:grid-cols-2">
            <label class="form-control">
              <span class="label-text text-xs">프로젝트</span>
              <select name="project_id" class="select select-bordered select-sm">
                <option :for={p <- @projects} value={p.id}>{p.title}</option>
              </select>
            </label>

            <label class="form-control">
              <span class="label-text text-xs">채널</span>
              <select name="channel_slug" class="select select-bordered select-sm">
                <option :for={c <- @channels} value={c.slug}>{c.display_name}</option>
              </select>
            </label>
          </div>

          <div class="grid gap-3 md:grid-cols-2">
            <label class="form-control">
              <span class="label-text text-xs">영상 URL</span>
              <input name="external_url" placeholder="https://youtu.be/..." class="input input-bordered input-sm" />
            </label>

            <label class="form-control">
              <span class="label-text text-xs">제목 (비우면 프로젝트 제목)</span>
              <input name="title" class="input input-bordered input-sm" />
            </label>
          </div>

          <button type="submit" class="btn btn-primary btn-sm w-fit">등록</button>
        </div>
      </form>

      <div :if={@publications == []} class="mt-8 text-base-content/60">
        아직 발행된 영상이 없습니다. <strong>올린 영상 등록</strong> 으로 이미 올린 것을 넣으면
        여기서 조회수·좋아요·댓글을 집계합니다.
      </div>

      <div :if={@publications != []} class="mt-8">
        <h2 class="mb-2 text-lg font-semibold">발행물별</h2>
        <p class="mb-2 text-sm text-base-content/60">
          「유튜브에서 수집」 을 누르면 여기가 채워진다. 잴 때마다 새 줄로 쌓여서 증가 추이가 남는다.
        </p>

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>영상</th>
                <th class="text-right">조회수</th>
                <th class="text-right">좋아요</th>
                <th class="text-right">댓글</th>
                <th>잰 때</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={p <- @publications}>
                <td class="max-w-[20rem]">
                  <div class="truncate text-sm font-medium">{p.project.title}</div>
                  <div class="font-mono text-xs opacity-60">{p.channel.slug} · {p.project.language}</div>
                </td>
                <td class="text-right font-mono">{(p.latest && p.latest.views) || "—"}</td>
                <td class="text-right font-mono">{(p.latest && p.latest.likes) || "—"}</td>
                <td class="text-right font-mono">{(p.latest && p.latest.comments) || "—"}</td>
                <td class="text-xs opacity-60">
                  {(p.latest && when_measured(p.latest.collected_at)) || "아직 안 쟀습니다"}
                </td>
                <td>
                  <a :if={p.external_url != ""} href={p.external_url} target="_blank" class="link text-xs">
                    열기
                  </a>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div :if={@data.measured > 0} class="mt-8 grid gap-6 lg:grid-cols-3">
        <.breakdown title="채널별" rows={@data.by_channel} />
        <.breakdown title="언어별" rows={@data.by_language} />
        <.breakdown title="영상별" rows={@data.by_project} />
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp stat(assigns) do
    ~H"""
    <div class="stat rounded bg-base-200 p-3">
      <div class="stat-title text-xs">{@label}</div>
      <div class="stat-value text-2xl">{number(@value)}</div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true

  defp breakdown(assigns) do
    ~H"""
    <div>
      <h3 class="mb-2 font-semibold">{@title}</h3>
      <table class="table table-xs">
        <thead>
          <tr>
            <th></th>
            <th class="text-right">조회</th>
            <th class="text-right">좋아요</th>
            <th class="text-right">댓글</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={r <- @rows}>
            <td class="max-w-[10rem] truncate">{r.key}</td>
            <td class="text-right">{number(r.views)}</td>
            <td class="text-right">{number(r.likes)}</td>
            <td class="text-right">{number(r.comments)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # 천 단위 구분. 큰 숫자를 붙여 쓰면 자릿수를 잘못 읽는다.
  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp number(n), do: to_string(n)
end