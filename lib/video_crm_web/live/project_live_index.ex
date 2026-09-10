defmodule VideoCRMWeb.ProjectLive.Index do
  @moduledoc "프로젝트 목록. 어디까지 왔는지만 본다."
  use VideoCRMWeb, :live_view

  alias VideoCRM.{Media, Projects}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :projects, load())}
  end

  defp load do
    Enum.map(Projects.list_projects(), fn p ->
      scenes = length(Projects.scenes(p.id))
      mapped = Media.mapped_counts(p.id)

      %{
        id: p.id,
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
          <.link navigate={~p"/projects/#{p.id}"} class="font-semibold hover:underline">
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
      </.table>
    </Layouts.app>
    """
  end

  defp progress(_done, 0), do: "-"
  defp progress(done, total), do: "#{done}/#{total}"
end