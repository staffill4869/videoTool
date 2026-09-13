defmodule VideoToolWeb.PromptLive do
  @moduledoc """
  프롬프트 편집.

  프롬프트가 A4 2~4장이고 실제로 바뀌는 건 일부 절뿐이라, 통째로 다시 쓰는 대신
  **바꿔 끼울 칸**을 이름 붙여 빼뒀다. 여기서 그 값들과 본문을 고친다.

  저장하면 덮어쓰지 않고 새 버전을 만든다 — 프롬프트를 고치면 결과가 통째로 바뀌는데,
  어떤 판이 좋았는지는 몇 편 만들어 본 뒤에야 안다.
  """
  use VideoToolWeb, :live_view

  alias VideoTool.{Presets, Projects, Prompt}

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
    domains = Presets.list_domains()
    projects = Projects.list_projects()

    socket
    |> assign(
      styles: styles,
      style: style,
      domains: domains,
      domain: List.first(domains),
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

  # 같은 폼에 버튼이 둘이다. '새로' 버튼은 _blank 를 실어 보내 빈 그림체를 만든다.
  def handle_event("duplicate_style", %{"name" => name, "_blank" => _}, socket) do
    handle_style_result(Presets.create_style(name), socket)
  end

  def handle_event("duplicate_style", %{"name" => name}, socket) do
    handle_style_result(Presets.duplicate_style(socket.assigns.style, name), socket)
  end

  def handle_event("delete_style", _params, socket) do
    case Presets.delete_style(socket.assigns.style) do
      {:ok, style} ->
        styles = Presets.list_styles()

        {:noreply,
         socket
         |> put_flash(:info, "'#{style.name}' 을 지웠습니다")
         |> assign(styles: styles, style: List.first(styles))
         |> assign_body()}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "지우지 못했습니다")}
    end
  end

  def handle_event("select_style", %{"style_id" => id}, socket) do
    {:noreply, assign(socket, style: Presets.get_style!(id))}
  end

  def handle_event("save_style", params, socket) do
    attrs = Map.take(params, ~w(name default_aspect global_style clean_rules camera_rules asset_definitions))

    case Presets.update_style(socket.assigns.style, attrs) do
      {:ok, style} ->
        {:noreply,
         socket
         |> put_flash(:info, "'#{style.name}' 저장했습니다")
         |> assign(styles: Presets.list_styles(), style: style)}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, "저장하지 못했습니다: #{inspect(cs.errors)}")}
    end
  end

  def handle_event("select_domain", %{"domain_id" => id}, socket) do
    {:noreply, assign(socket, domain: Presets.get_domain_by_id!(id))}
  end

  def handle_event("duplicate_domain", %{"name" => name, "_blank" => _}, socket) do
    handle_domain_result(Presets.create_domain(name), socket)
  end

  def handle_event("duplicate_domain", %{"name" => name}, socket) do
    handle_domain_result(Presets.duplicate_domain(socket.assigns.domain, name), socket)
  end

  def handle_event("delete_domain", _params, socket) do
    case Presets.delete_domain(socket.assigns.domain) do
      {:ok, d} ->
        domains = Presets.list_domains()

        {:noreply,
         socket
         |> put_flash(:info, "'#{d.name}' 을 지웠습니다")
         |> assign(domains: domains, domain: List.first(domains))}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "지우지 못했습니다")}
    end
  end

  def handle_event("save_domain", params, socket) do
    attrs =
      params
      |> Map.take(~w(name info_rules element_list video_topic_rules))
      |> Map.put("color_semantics", parse_colors(params["color_semantics"]))

    case Presets.update_domain(socket.assigns.domain, attrs) do
      {:ok, d} ->
        {:noreply,
         socket
         |> put_flash(:info, "'#{d.name}' 저장했습니다")
         |> assign(domains: Presets.list_domains(), domain: d)}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, "저장하지 못했습니다: #{inspect(cs.errors)}")}
    end
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

  defp handle_style_result({:ok, style}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "'#{style.name}' 을 만들었습니다 (slug: #{style.slug})")
     |> assign(styles: Presets.list_styles(), style: style)
     |> assign_body()}
  end

  defp handle_style_result({:error, %Ecto.Changeset{} = cs}, socket) do
    {:noreply, put_flash(socket, :error, "만들지 못했습니다: #{inspect(cs.errors)}")}
  end

  defp handle_style_result({:error, reason}, socket) do
    {:noreply, put_flash(socket, :error, reason)}
  end

  # 프롬프트가 {{style.*}} 로 꽂아 쓰는 네 덩이. 무엇이 어디에 들어가는지 화면에 적어둔다 —
  # 이름만 봐서는 clean_rules 와 global_style 의 차이를 알 수 없다.
  defp handle_domain_result({:ok, d}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "'#{d.name}' 을 만들었습니다 (slug: #{d.slug})")
     |> assign(domains: Presets.list_domains(), domain: d)}
  end

  defp handle_domain_result({:error, %Ecto.Changeset{} = cs}, socket) do
    {:noreply, put_flash(socket, :error, "만들지 못했습니다: #{inspect(cs.errors)}")}
  end

  defp handle_domain_result({:error, reason}, socket) do
    {:noreply, put_flash(socket, :error, reason)}
  end

  defp domain_fields do
    [
      {"info_rules", "INFO 규칙", "이 장르에서 지켜야 할 표기·금지 사항"},
      {"element_list", "사용 요소", "쓸 수 있는 인포그래픽 요소 목록"},
      {"video_topic_rules", "주제별 연출", "주제 유형마다 자동으로 적용할 연출"}
    ]
  end

  defp color_lines(map) when is_map(map),
    do: map |> Enum.sort() |> Enum.map_join("
", fn {k, v} -> "#{k}=#{v}" end)

  defp color_lines(_), do: ""

  # '이름=색' 줄을 map 으로. 등호가 없는 줄은 조용히 버린다 — 잘못 친 줄 하나로 저장이 막히면 곤란하다.
  defp parse_colors(nil), do: %{}

  defp parse_colors(text) do
    text
    |> String.split("
")
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [k, v] ->
          k = String.trim(k)
          v = String.trim(v)
          if k != "" and v != "", do: [{k, v}], else: []

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  defp style_fields do
    [
      {"global_style", "전역 스타일", "모든 단계에 공통으로 들어가는 화풍 기술"},
      {"clean_rules", "CLEAN 규칙", "글자 없는 원본 이미지를 만들 때의 금지·유지 사항"},
      {"camera_rules", "카메라 규칙", "VIDEO 단계의 카메라 연출 범위"},
      {"asset_definitions", "공통 에셋", "여러 컷에 반복 등장하는 대상의 생김새 고정"}
    ]
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
          <h2 class="mb-2 font-semibold">그림체</h2>

          <form phx-change="select_style" class="mb-2">
            <select name="style_id" class="select select-bordered select-sm w-full">
              <option :for={s <- @styles} value={s.id} selected={@style && s.id == @style.id}>
                {s.name}
              </option>
            </select>
          </form>

          <%!-- 복제가 기본이다. 규칙 네 덩이 + 변수 열 개를 백지에서 채울 일이 드물어서다.
                다만 완전히 다른 화풍을 시작할 땐 남의 규칙이 방해가 되므로 '새로'도 남겨둔다. --%>
          <form :if={@style} phx-submit="duplicate_style" class="mb-3 flex gap-2">
            <input
              name="name"
              placeholder={"#{@style.name} 복사본"}
              required
              class="input input-bordered input-sm flex-1"
            />
            <button type="submit" class="btn btn-sm">복제</button>
            <button type="submit" phx-submit="create_style" name="_blank" value="1" class="btn btn-ghost btn-sm">
              새로
            </button>
            <button
              :if={length(@styles) > 1}
              type="button"
              phx-click="delete_style"
              data-confirm={"'#{@style.name}' 을 지웁니다. 되돌릴 수 없습니다."}
              class="btn btn-ghost btn-sm text-error"
            >
              삭제
            </button>
          </form>

          <%!-- 규칙 본문도 여기서 고친다. 변수만 열어두면 '새로' 로 만든 빈 그림체를
                채울 방법이 없어서, 만들 수는 있는데 쓸 수는 없는 상태가 된다. --%>
          <form :if={@style} phx-submit="save_style" class="mb-4 space-y-2">
            <div class="flex gap-2">
              <input
                name="name"
                value={@style.name}
                required
                placeholder="그림체 이름"
                class="input input-bordered input-sm flex-1"
              />
              <select name="default_aspect" class="select select-bordered select-sm w-28">
                <option :for={a <- ~w(16:9 9:16)} value={a} selected={a == @style.default_aspect}>
                  {a}
                </option>
              </select>
            </div>

            <label :for={{field, label, hint} <- style_fields()} class="block">
              <span class="mb-1 block text-xs opacity-70">
                {label}<span class="ml-1 opacity-60">— {hint}</span>
              </span>
              <textarea
                name={field}
                rows="5"
                class="textarea textarea-bordered textarea-sm w-full font-mono text-xs"
              >{Map.get(@style, String.to_existing_atom(field))}</textarea>
            </label>

            <div class="flex items-center gap-2">
              <button type="submit" class="btn btn-primary btn-sm">그림체 저장</button>
              <span class="text-xs opacity-50">slug: {@style.slug}</span>
            </div>
          </form>

          <h3 class="mb-2 font-semibold">변수</h3>

          <form :if={@style} phx-submit="save_variables">
            <div class="space-y-2">
              <div :for={{name, value} <- Enum.sort(@style.variables || %{})} class="flex gap-2">
                <input
                  name="name[]"
                  value={name}
                  placeholder="이름"
                  class="input input-bordered input-sm w-32 font-mono"
                />
                <.variable_value name={name} value={value} />
              </div>
            </div>

            <div class="mt-3 flex gap-2">
              <button type="button" phx-click="add_variable" class="btn btn-ghost btn-sm">
                칸 추가
              </button>
              <button type="submit" class="btn btn-primary btn-sm">변수 저장</button>
            </div>
          </form>

          <h2 class="mt-6 mb-2 font-semibold">장르</h2>

          <form phx-change="select_domain" class="mb-2">
            <select name="domain_id" class="select select-bordered select-sm w-full">
              <option :for={d <- @domains} value={d.id} selected={@domain && d.id == @domain.id}>
                {d.name}
              </option>
            </select>
          </form>

          <form :if={@domain} phx-submit="duplicate_domain" class="mb-3 flex gap-2">
            <input
              name="name"
              placeholder={"#{@domain.name} 복사본"}
              required
              class="input input-bordered input-sm flex-1"
            />
            <button type="submit" class="btn btn-sm">복제</button>
            <button type="submit" name="_blank" value="1" class="btn btn-ghost btn-sm">새로</button>
            <button
              :if={length(@domains) > 1}
              type="button"
              phx-click="delete_domain"
              data-confirm={"'#{@domain.name}' 을 지웁니다. 되돌릴 수 없습니다."}
              class="btn btn-ghost btn-sm text-error"
            >
              삭제
            </button>
          </form>

          <form :if={@domain} phx-submit="save_domain" class="space-y-2">
            <input
              name="name"
              value={@domain.name}
              required
              placeholder="장르 이름"
              class="input input-bordered input-sm w-full"
            />

            <label :for={{field, label, hint} <- domain_fields()} class="block">
              <span class="mb-1 block text-xs opacity-70">
                {label}<span class="ml-1 opacity-60">— {hint}</span>
              </span>
              <textarea
                name={field}
                rows="5"
                class="textarea textarea-bordered textarea-sm w-full font-mono text-xs"
              >{Map.get(@domain, String.to_existing_atom(field))}</textarea>
            </label>

            <%!-- 색 의미는 map 이라 한 줄씩 '이름=색' 으로 받는다. 표 UI 를 따로 만들 만큼 자주 고치지 않는다. --%>
            <label class="block">
              <span class="mb-1 block text-xs opacity-70">
                색 규칙<span class="ml-1 opacity-60">— 한 줄에 하나씩 <code>이름=색</code></span>
              </span>
              <textarea
                name="color_semantics"
                rows="4"
                class="textarea textarea-bordered textarea-sm w-full font-mono text-xs"
              >{color_lines(@domain.color_semantics)}</textarea>
            </label>

            <div class="flex items-center gap-2">
              <button type="submit" class="btn btn-primary btn-sm">장르 저장</button>
              <span class="text-xs opacity-50">slug: {@domain.slug}</span>
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

  # 선택지가 있는 변수는 고르게, 없는 변수는 그대로 자유 입력.
  # 고른 값이 목록에 없으면(직접 고쳐 쓴 경우) 목록에 얹어 보여준다 — 안 그러면
  # 저장돼 있던 값이 화면에서 조용히 사라진다.
  attr :name, :string, required: true
  attr :value, :string, required: true

  defp variable_value(assigns) do
    choices = Presets.choices_for(assigns.name)
    known? = choices && Enum.any?(choices, fn {_label, v} -> v == assigns.value end)
    assigns = assign(assigns, choices: choices, known?: known?)

    ~H"""
    <select :if={@choices} name="value[]" class="select select-bordered select-sm flex-1">
      <option :if={!@known? and @value not in [nil, ""]} value={@value} selected>
        직접 입력한 값 — {String.slice(@value, 0, 40)}
      </option>
      <option :for={{label, v} <- @choices} value={v} selected={v == @value}>{label}</option>
    </select>
    <input
      :if={!@choices}
      name="value[]"
      value={@value}
      placeholder="값"
      class="input input-bordered input-sm flex-1"
    />
    """
  end
end