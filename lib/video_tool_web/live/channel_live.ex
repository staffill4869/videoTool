defmodule VideoToolWeb.ChannelLive do
  @moduledoc """
  발행 채널. 유튜브·인스타 계정을 연결하고, 어디로 올릴지 고른다.

  실제 토큰은 여기 없다 — `VideoTool.Credentials` 가 Windows DPAPI 로 암호화해 파일에 둔다.
  DB 가 유출돼도 계정이 털리지 않게 하기 위해서다(설명서 7장).

  발행은 이 화면에서 자동으로 일어나지 않는다. 되돌릴 수 없는 공개 행위라
  사람이 누를 때만 나간다.
  """
  use VideoToolWeb, :live_view

  alias VideoTool.{Credentials, Media, Projects, Publishing}
  alias VideoTool.Publishing.Channel

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(project_id: nil) |> load()}
  end

  defp load(socket) do
    projects = Projects.list_projects()
    project_id = socket.assigns[:project_id] || (projects |> List.first() |> then(&(&1 && &1.id)))

    assign(socket,
      channels: Enum.map(Publishing.list_channels(), &decorate/1),
      projects: projects,
      project_id: project_id,
      renders: (project_id && Media.renders(project_id)) || [],
      publications: (project_id && Publishing.publications(project_id)) || []
    )
  end

  defp decorate(channel) do
    %{
      row: channel,
      token_saved: Credentials.exists?(channel.credential_ref),
      token_valid: Channel.token_valid?(channel)
    }
  end

  # ── 이벤트 ──────────────────────────────────────────────────────

  @impl true
  def handle_event("select_project", %{"project_id" => id}, socket) do
    {:noreply, socket |> assign(project_id: String.to_integer(id)) |> load()}
  end

  def handle_event("disconnect", %{"slug" => slug}, socket) do
    {:ok, channel} = Publishing.fetch_channel(slug)
    Credentials.delete(channel.credential_ref)

    # 행은 남긴다 — 재연결이 같은 행을 되살려야 발행 이력이 떨어져 나가지 않는다.
    {:ok, _} = Publishing.update_channel(channel, %{token_expires_at: nil})

    {:noreply, socket |> put_flash(:info, "#{channel.display_name} 연결을 끊었습니다") |> load()}
  end

  def handle_event("publish", %{"publication_id" => id}, socket) do
    with {:ok, publication} <- Publishing.get_publication(id),
         {:ok, project} <- Projects.get_project(publication.project_id) do
      case Publishing.publish(project, publication.channel, publication.render, true) do
        {:ok, result} ->
          {:noreply, socket |> put_flash(:info, "발행했습니다: #{result.external_url}") |> load()}

        {:error, reasons} when is_list(reasons) ->
          {:noreply, put_flash(socket, :error, Enum.join(reasons, " / "))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  # ── 화면 ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:channels}>
      <.header>
        발행 채널
        <:subtitle>
          토큰은 DB 가 아니라 Windows 자격증명(DPAPI)에 있다. 발행은 사람이 누를 때만 나간다.
        </:subtitle>
      </.header>

      <div class="mt-4 grid gap-3 md:grid-cols-3">
        <div :for={c <- @channels} class="card bg-base-200">
          <div class="card-body gap-2 p-4">
            <div class="flex items-start justify-between">
              <div>
                <div class="font-semibold">{c.row.display_name}</div>
                <div class="font-mono text-xs opacity-60">{c.row.slug} · {c.row.platform}</div>
              </div>
              <span class={["badge badge-sm", status_class(c)]}>{status_text(c)}</span>
            </div>

            <div class="text-xs opacity-70">
              화면비 {c.row.aspect_required} ·
              {if c.row.max_duration_sec == 0, do: "길이 제한 없음", else: "최대 #{c.row.max_duration_sec}초"} ·
              기본 공개범위 {c.row.default_privacy}
            </div>

            <div class="mt-1 flex gap-2">
              <span :if={not c.token_saved} class="text-xs opacity-60">
                아직 연결 안 됨 — OAuth 설정이 필요합니다
              </span>
              <button
                :if={c.token_saved}
                phx-click="disconnect"
                phx-value-slug={c.row.slug}
                class="btn btn-ghost btn-xs"
              >
                연결 끊기
              </button>
            </div>
          </div>
        </div>
      </div>

      <div class="alert alert-info mt-4 text-sm">
        <div>
          <div class="font-semibold">연결하려면 먼저 준비가 필요합니다</div>
          <ul class="mt-1 list-disc pl-5">
            <li>유튜브 — GCP 프로젝트 · YouTube Data API v3 사용 설정 · OAuth 클라이언트 ID(데스크톱 앱)</li>
            <li>인스타 — 프로페셔널 계정 · 페이스북 페이지 연결 · Meta 앱 검수 · 공개 URL 호스팅</li>
          </ul>
          <div class="mt-1 opacity-70">
            준비되면 <code class="font-mono">.env</code> 에 넣고 여기서 연결 버튼이 열립니다.
          </div>
        </div>
      </div>

      <h2 class="mt-8 mb-2 text-lg font-semibold">발행 대기</h2>

      <form phx-change="select_project" class="mb-3 max-w-sm">
        <select name="project_id" class="select select-bordered select-sm w-full">
          <option :for={p <- @projects} value={p.id} selected={p.id == @project_id}>
            {p.title}
          </option>
        </select>
      </form>

      <div :if={@renders == []} class="text-sm opacity-60">
        완성본이 아직 없습니다. 합성(assemble)까지 끝나야 발행할 수 있습니다.
      </div>

      <table :if={@publications != []} class="table table-sm">
        <thead>
          <tr>
            <th>채널</th>
            <th>제목</th>
            <th>공개범위</th>
            <th>상태</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={p <- @publications}>
            <td class="font-mono text-xs">{p.channel.slug}</td>
            <td class="max-w-md truncate">{p.title}</td>
            <td>{p.privacy}</td>
            <td><span class="badge badge-sm">{p.status}</span></td>
            <td>
              <button
                :if={p.status == "draft"}
                phx-click="publish"
                phx-value-publication_id={p.id}
                data-confirm={"#{p.channel.display_name} 에 실제로 발행합니다. 되돌릴 수 없습니다."}
                class="btn btn-primary btn-xs"
              >
                발행
              </button>
              <a :if={p.external_url != ""} href={p.external_url} target="_blank" class="link text-xs">
                열기
              </a>
            </td>
          </tr>
        </tbody>
      </table>

      <div :if={@publications == [] and @renders != []} class="text-sm opacity-60">
        발행 초안이 없습니다. MCP 의 <code class="font-mono">save_publish_meta</code> 로
        제목·설명·해시태그를 먼저 저장하세요 (AI 가 씁니다).
      </div>
    </Layouts.app>
    """
  end

  defp status_class(%{token_valid: true}), do: "badge-success"
  defp status_class(%{token_saved: true}), do: "badge-warning"
  defp status_class(_), do: "badge-ghost"

  defp status_text(%{token_valid: true}), do: "연결됨"
  defp status_text(%{token_saved: true}), do: "토큰 만료"
  defp status_text(_), do: "미연결"
end