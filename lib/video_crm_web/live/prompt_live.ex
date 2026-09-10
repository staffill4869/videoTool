defmodule VideoCRMWeb.PromptLive do
  @moduledoc """
  프롬프트 편집.

  프롬프트가 A4 2~4장이고 실제로 바뀌는 건 일부 절뿐이라, 통째로 다시 쓰는 대신
  **바꿔 끼울 칸**을 이름 붙여 빼뒀다. 여기서 그 값들과 본문을 고친다.

  저장하면 덮어쓰지 않고 새 버전을 만든다 — 프롬프트를 고치면 결과가 통째로 바뀌는데,
  어떤 판이 좋았는지는 몇 편 만들어 본 뒤에야 안다.
  """
  use VideoCRMWeb, :live_view

  alias VideoCRM.{Presets, Projects, Prompt}

  @stages ~w(clean info video)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(stage: "clean", preview: nil, missing: [], dirty: false)
     |> load()}
  end

  defp load(socket) do
    styles = Presets.list_styles()
    style = List.first(styles)
    projects = Projects.list_projects()

    socket
    |> assign(
      styles: styles,
      style: style,
      projects: projects,
      project_id: projects |> List.first() |> then(&(&1 && &1.id)),
      templates: Map.new(@stages, &{&1, active_template(&1)})
    )
    |> assign_body()
  end

  defp active_template(stage) do
    case Presets.fetch_template(stage) do
      {:ok, t} -> t
      {:error, _} -> nil
    end
  end

  defp assign_body(socket) do
    template = socket.assigns.templates[socket.assigns.stage]
    assign(socket, body: (template && template.body) || "", template: template)
  end

  # ── 이벤트 ──────────────────────────────────────────────────────

  @impl true
  def handle_event("stage", %{"stage" => stage}, socket) when stage in @stages do
    {:noreply, socket |> assign(stage: stage, dirty: false, preview: nil) |> assign_body()}
  end

  def handle_event("edit_body", %{"body" => body}, socket) do
    {:noreply, assign(socket, body: body, dirty: body != (socket.assigns.template && socket.assigns.template.body))}
  end

  def handle_event("save_body", _params, socket) do
    case Presets.save_template(socket.assigns.stage, socket.assigns.body) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> put_flash(:info, "v#{saved.version} 로 저장했습니다")
         |> assign(dirty: false, templates: Map.put(socket.assigns.templates, saved.stage, saved))
         |> assign_body()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "저장하지 못했습니다")}
    end
  end

  def handle_event("select_style", %{"style_id" => id}, socket) do
    {:noreply, assign(socket, style: Presets.get_style!(id))}
  end

  def handle_event("save_variables", %{"name" => names, "value" => values}, socket) do
    variables =
      Enum.zip(names, values)
      |> Enum.reject(fn {name, _} -> String.trim(name) == "" end)
      |> Map.new(fn {name, value} -> {String.trim(name), value} end)

    case Presets.update_style(socket.assigns.style, %{variables: variables}) do
      {:ok, style} ->
        {:noreply, socket |> put_flash(:info, "변수 #{map_size(variables)}개 저장") |> assign(style: style)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "저장하지 못했습니다")}
    end
  end

  def handle_event("add_variable", _params, socket) do
    variables = Map.put(socket.assigns.style.variables || %{}, "", "")
    {:noreply, assign(socket, style: %{socket.assigns.style | variables: variables})}
  end

  def handle_event("preview", %{"project_id" => id}, socket) do
    {:noreply, preview(socket, id)}
  end

  def handle_event("preview", _params, socket) do
    {:noreply, preview(socket, socket.assigns.project_id)}
  end

  defp preview(socket, nil), do: put_flash(socket, :error, "미리 볼 프로젝트가 없습니다")

  defp preview(socket, id) do
    with {:ok, project} <- Projects.get_project(id) do
      # 저장 안 한 본문으로 미리 본다 — 저장해야만 확인할 수 있으면 고칠 엄두가 안 난다.
      text = Prompt.preview(project, socket.assigns.stage, socket.assigns.body)
      {:ok, missing} = Prompt.missing_variables(project, socket.assigns.stage)

      assign(socket, preview: text, missing: missing, project_id: id)
    else
      {:error, reason} -> put_flash(socket, :error, reason)
    end
  end

  # ── 화면 ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:prompts}>
      <.header>
        프롬프트
        <:subtitle>
          바꿔 끼울 칸은 <code class="font-mono">{"{{var.이름}}"}</code> 으로 빼둔다.
          저장하면 덮어쓰지 않고 새 버전이 된다.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">프로젝트</.link>
        </:actions>
      </.header>

      <div role="tablist" class="tabs tabs-bordered mt-4">
        <button
          :for={s <- ~w(clean info video)}
          role="tab"
          phx-click="stage"
          phx-value-stage={s}
          class={["tab", @stage == s && "tab-active"]}
        >
          {String.upcase(s)}
          <span :if={@templates[s]} class="ml-1 text-xs opacity-60">v{@templates[s].version}</span>
        </button>
      </div>

      <div class="mt-4 grid gap-6 lg:grid-cols-2">
        <div>
          <div class="mb-2 flex items-center justify-between">
            <h2 class="font-semibold">본문</h2>
            <div class="flex items-center gap-2">
              <span :if={@dirty} class="text-xs text-warning">저장 안 됨</span>
              <span class="text-xs opacity-60">{String.length(@body)}자</span>
              <.button phx-click="save_body" disabled={not @dirty} class="btn-primary btn-xs">
                새 버전으로 저장
              </.button>
            </div>
          </div>

          <form phx-change="edit_body">
            <textarea
              name="body"
              rows="26"
              class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed"
              phx-debounce="400"
            >{@body}</textarea>
          </form>

          <div class="mt-2 text-xs opacity-60">
            쓸 수 있는 슬롯: project.aspect · project.target_sec · project.target_chars ·
            scene_count · script · scenes · allowed_facts ·
            style.clean_rules · style.camera_rules · style.global_style · style.asset_definitions ·
            domain.info_rules · domain.element_list · domain.color_semantics · domain.video_topic_rules
          </div>
        </div>

        <div>
          <h2 class="mb-2 font-semibold">변수</h2>

          <form phx-change="select_style" class="mb-3">
            <select name="style_id" class="select select-bordered select-sm w-full">
              <option :for={s <- @styles} value={s.id} selected={@style && s.id == @style.id}>
                {s.name}
              </option>
            </select>
          </form>

          <form :if={@style} phx-submit="save_variables">
            <div class="space-y-2">
              <div :for={{name, value} <- Enum.sort(@style.variables || %{})} class="flex gap-2">
                <input
                  name="name[]"
                  value={name}
                  placeholder="이름"
                  class="input input-bordered input-sm w-32 font-mono"
                />
                <input
                  name="value[]"
                  value={value}
                  placeholder="값"
                  class="input input-bordered input-sm flex-1"
                />
              </div>
            </div>

            <div class="mt-3 flex gap-2">
              <button type="button" phx-click="add_variable" class="btn btn-ghost btn-sm">
                칸 추가
              </button>
              <button type="submit" class="btn btn-primary btn-sm">변수 저장</button>
            </div>
          </form>

          <h2 class="mt-6 mb-2 font-semibold">미리보기</h2>
          <form phx-change="preview" class="mb-2 flex gap-2">
            <select name="project_id" class="select select-bordered select-sm flex-1">
              <option :for={p <- @projects} value={p.id} selected={p.id == @project_id}>
                {p.title}
              </option>
            </select>
          </form>

          <div :if={@missing != []} class="alert alert-warning mb-2 py-2 text-sm">
            값이 없는 변수: {Enum.join(@missing, ", ")} — 프롬프트에 ⟨미설정⟩ 으로 들어갑니다
          </div>

          <pre
            :if={@preview}
            class="max-h-96 overflow-auto rounded border border-base-300 bg-base-200 p-3 text-xs whitespace-pre-wrap"
          >{@preview}</pre>

          <div :if={is_nil(@preview)} class="text-sm opacity-60">
            프로젝트를 고르면 실제로 Flow 에 들어갈 모습을 보여줍니다.
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end