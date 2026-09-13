defmodule VideoToolWeb.ProjectLive.Index do
  @moduledoc "프로젝트 목록. 어디까지 왔는지만 본다."
  use VideoToolWeb, :live_view

  alias VideoTool.{Media, Projects, Series}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :projects, load())}
  end

  defp load do
    # 색은 시리즈가 정한다 — /series 에서 본 그 색이 여기 그대로 온다.
    colors = Series.color_map()

    Enum.map(Projects.list_projects(), fn p ->
      scenes = length(Projects.scenes(p.id))
      mapped = Media.mapped_counts(p.id)

      %{
        id: p.id,
        color: Map.get(colors, p.series_id, "transparent"),
        title: p.title,
        status: p.status,
        aspect: p.aspect,
        voice: p.voice.display_name,
        scenes: scenes,
        clean: mapped["clean"],
        info: mapped["info"],
        clip: mapped["clip"]
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:projects}>
      <.header>
        프로젝트
        <:subtitle>조작은 MCP 로 한다. 이 화면은 매핑이 맞는지 눈으로 보는 곳이다.</:subtitle>
      </.header>

      <div :if={@projects == []} class="mt-8 text-base-content/60">
        아직 프로젝트가 없습니다. MCP 의 <code class="font-mono">create_project</code> 로 만드세요.
      </div>

      <.table :if={@projects != []} id="projects" rows={@projects}>
        <:col :let={p} label="제목">
          <.link
            navigate={~p"/projects/#{p.id}"}
            class="flex items-center gap-2 font-semibold hover:underline"
          >
            <span style={"display:inline-block;width:12px;height:12px;border-radius:9999px;flex:none;background:#{p.color}"}></span>
            {p.title}
          </.link>
        </:col>
        <:col :let={p} label="상태"><span class="badge badge-sm">{p.status}</span></:col>
        <:col :let={p} label="장면">{p.scenes}</:col>
        <:col :let={p} label="CLEAN">{progress(p.clean, p.scenes)}</:col>
        <:col :let={p} label="INFO">{progress(p.info, p.scenes)}</:col>
        <:col :let={p} label="클립">{progress(p.clip, p.scenes)}</:col>
        <:col :let={p} label="화면비">{p.aspect}</:col>
        <:col :let={p} label="보이스">{p.voice}</:col>
        <:col :let={p} label="">
          <button
            phx-click="delete"
            phx-value-id={p.id}
            data-confirm={"'#{p.title}' 을(를) 지웁니다. 대본·장면·자산 기록이 함께 사라집니다. (파일은 디스크에 남습니다)"}
            class="btn btn-ghost btn-xs text-error"
          >
            삭제
          </button>
        </:col>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, project} <- Projects.get_project(id),
         {:ok, _} <- Projects.delete_project(project) do
      {:noreply,
       socket
       |> put_flash(:info, "'#{project.title}' 을(를) 지웠습니다. 만들어진 파일은 디스크에 남아 있습니다.")
       |> assign(:projects, load())}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, "지우지 못했습니다: #{inspect(reason)}")}
    end
  end

  defp progress(_done, 0), do: "-"
  defp progress(done, total), do: "#{done}/#{total}"
end