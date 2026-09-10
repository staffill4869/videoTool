defmodule VideoCRMWeb.ProjectLive.Show do
  @moduledoc """
  컨택트시트. 장면마다 CLEAN / INFO / 클립을 나란히 놓고 매핑이 맞는지 눈으로 본다.

  설명서 §5.2 가 CLEAN 단계에 한해 "사용자에게 컨택트시트를 보여주고 확정받는 것" 을 허용한다.
  파일명이 내용과 무관해서 자동 매핑이 틀릴 수 있는데, 틀린 걸 볼 방법이 없으면
  틀린 채로 영상이 나간다.
  """
  use VideoCRMWeb, :live_view

  alias VideoCRM.{Jobs, Mapping, Media, Pipeline, Projects, Prompt, Validation}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Projects.get_project(id) do
      {:ok, project} -> {:ok, socket |> assign(:last_action, nil) |> load(project)}
      {:error, reason} -> {:ok, socket |> put_flash(:error, reason) |> push_navigate(to: ~p"/projects")}
    end
  end

  defp load(socket, project) do
    scenes = Projects.scenes(project.id)
    script = Projects.active_script(project.id)

    assign(socket,
      project: project,
      scenes: scenes,
      segments: Projects.segments_by_scene(script && script.id),
      by_scene: Media.assets_by_scene(project.id),
      unassigned: Media.unassigned_assets(project.id),
      validations: Map.new(~w(clean info clips final), &{&1, Jobs.latest_validation(project.id, &1)}),
      counts: Media.mapped_counts(project.id),
      variants: Projects.variants(project.id),
      languages: Projects.language_names(),
      voices: VideoCRM.Presets.list_voices()
    )
    |> load_prompt()
  end

  defp load_prompt(socket) do
    project = socket.assigns.project
    stage = socket.assigns[:prompt_stage] || "clean"

    {body, rendered, missing} =
      case Prompt.body_for(project, stage) do
        {:ok, body} ->
          {:ok, text} = Prompt.render(project, stage)
          {:ok, miss} = Prompt.missing_variables(project, stage)
          {body, text, miss}

        {:error, reason} ->
          {"", reason, []}
      end

    assign(socket,
      prompt_stage: stage,
      prompt_body: body,
      prompt_rendered: rendered,
      prompt_missing: missing,
      prompt_overridden: Prompt.overridden?(project, stage),
      prompt_dirty: false
    )
  end

  defp reload(socket) do
    {:ok, project} = Projects.get_project(socket.assigns.project.id)
    load(socket, project)
  end

  # ── 이벤트 ──────────────────────────────────────────────────────

  @impl true
  def handle_event("run_next", _params, socket) do
    result = Pipeline.next(socket.assigns.project)
    {:noreply, socket |> assign(:last_action, result) |> reload()}
  end

  def handle_event("reassign", %{"asset_id" => asset_id, "scene_id" => scene_id}, socket) do
    asset = Media.get_asset(asset_id)
    target = if scene_id == "", do: nil, else: String.to_integer(scene_id)

    case Media.reassign(asset, target) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "장면을 옮겼습니다") |> reload()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "옮기지 못했습니다")}
    end
  end

  def handle_event("approve", %{"asset_id" => asset_id}, socket) do
    {:ok, _} = asset_id |> Media.get_asset() |> Media.approve()
    {:noreply, socket |> put_flash(:info, "확정했습니다") |> reload()}
  end

  def handle_event("prompt_stage", %{"stage" => stage}, socket) do
    {:noreply, socket |> assign(prompt_stage: stage) |> load_prompt()}
  end

  def handle_event("prompt_edit", %{"body" => body}, socket) do
    {:noreply, assign(socket, prompt_body: body, prompt_dirty: body != socket.assigns.prompt_body)}
  end

  def handle_event("prompt_save", %{"body" => body}, socket) do
    {:ok, project} =
      Projects.set_prompt_override(socket.assigns.project, socket.assigns.prompt_stage, body)

    {:ok, project} = Projects.get_project(project.id)

    {:noreply,
     socket
     |> put_flash(:info, "이 프로젝트 전용 프롬프트로 저장했습니다")
     |> load(project)}
  end

  def handle_event("prompt_reset", _params, socket) do
    {:ok, project} =
      Projects.set_prompt_override(socket.assigns.project, socket.assigns.prompt_stage, nil)

    {:ok, project} = Projects.get_project(project.id)
    {:noreply, socket |> put_flash(:info, "공용 템플릿으로 되돌렸습니다") |> load(project)}
  end

  def handle_event("make_variant", %{"language" => language} = params, socket) do
    case Projects.create_language_variant(socket.assigns.project, language,
           voice_slug: params["voice_slug"]
         ) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{Projects.language_label(language)} 판을 만들었습니다. " <>
             "CLEAN #{result.clean_reused}장은 원본과 공유합니다."
         )
         |> push_navigate(to: ~p"/projects/#{result.project.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  def handle_event("validate", %{"stage" => stage}, socket) do
    {:ok, result} = Validation.run(socket.assigns.project, stage)

    message =
      if result.passed,
        do: "#{stage} 검증 통과",
        else: "#{stage} 검증 실패 — 문제 #{length(result.problems)}건"

    {:noreply, socket |> put_flash(:info, message) |> reload()}
  end

  # ── 화면 ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:projects}>
      <.header>
        {@project.title}
        <:subtitle>
          {@project.topic} · {@project.aspect} · 목표 {@project.target_sec}초 · {@project.voice.display_name}
        </:subtitle>
        <:actions>
          <.link navigate={~p"/projects"} class="btn btn-ghost btn-sm">목록</.link>
          <.button phx-click="run_next" class="btn-primary btn-sm">다음 단계 실행</.button>
        </:actions>
      </.header>

      <div class="mt-4 flex flex-wrap gap-2 text-sm">
        <span class="badge badge-lg">{@project.status}</span>
        <span class="badge badge-lg badge-ghost">장면 {length(@scenes)}</span>
        <span :for={kind <- ~w(clean info clip)} class="badge badge-lg badge-ghost">
          {kind} {@counts[kind]}/{length(@scenes)}
        </span>
      </div>

      <div :if={@last_action} class="mt-4 alert" role="status">
        <div>
          <div class="font-semibold">
            {@last_action.stage} · {@last_action.action}
          </div>
          <div class="text-sm">{@last_action.message}</div>
          <div :if={@last_action[:warnings]} class="mt-2 text-sm text-warning">
            <div :for={w <- @last_action.warnings}>⚠ {w}</div>
          </div>
          <div :if={@last_action[:ingested]} class="mt-2 text-sm">
            가져옴: {@last_action.ingested.zip} — {@last_action.ingested.extracted}개 중
            {@last_action.ingested.mapped}개 매핑 ({@last_action.ingested.method})
          </div>
        </div>
      </div>

      <h2 class="mt-8 mb-2 text-lg font-semibold">검증</h2>
      <div class="flex flex-wrap gap-3">
        <div :for={{stage, validation} <- @validations} class="card card-compact bg-base-200 w-64">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <span class="font-mono text-sm">{stage}</span>
              <button phx-click="validate" phx-value-stage={stage} class="btn btn-xs">검사</button>
            </div>
            <div :if={validation} class={["text-sm", validation.passed && "text-success" || "text-error"]}>
              {(validation.passed && "통과") || "실패 #{length(validation.problems)}건"}
            </div>
            <div :if={validation} class="text-xs text-base-content/60">
              <div :for={{name, value} <- validation.checks}>
                {name}: {format_check(value)}
              </div>
            </div>
            <div :if={is_nil(validation)} class="text-sm text-base-content/50">아직 검사 안 함</div>
          </div>
        </div>
      </div>

      <h2 class="mt-8 mb-2 text-lg font-semibold">프롬프트</h2>

      <div role="tablist" class="tabs tabs-bordered">
        <button
          :for={s <- ~w(clean info video)}
          role="tab"
          phx-click="prompt_stage"
          phx-value-stage={s}
          class={["tab", @prompt_stage == s && "tab-active"]}
        >
          {String.upcase(s)}
        </button>
      </div>

      <div class="mt-3 grid gap-4 lg:grid-cols-2">
        <div>
          <div class="mb-1 flex items-center justify-between">
            <span class="text-sm font-semibold">
              Flow 에 넣을 최종본
              <span :if={@prompt_overridden} class="badge badge-warning badge-xs ml-1">전용</span>
              <span :if={not @prompt_overridden} class="badge badge-ghost badge-xs ml-1">공용</span>
            </span>
            <div class="flex items-center gap-2">
              <span id="copy-result" class="text-xs opacity-60"></span>
              <button
                phx-click={JS.dispatch("videocrm:copy", detail: %{text: @prompt_rendered})}
                class="btn btn-primary btn-xs"
              >
                복사
              </button>
            </div>
          </div>

          <div :if={@prompt_missing != []} class="alert alert-warning mb-2 py-2 text-xs">
            값 없는 변수: {Enum.join(@prompt_missing, ", ")}
          </div>

          <pre class="max-h-80 overflow-auto rounded border border-base-300 bg-base-200 p-3 text-xs whitespace-pre-wrap">{@prompt_rendered}</pre>
          <div class="mt-1 text-xs opacity-60">{String.length(@prompt_rendered)}자</div>
        </div>

        <div>
          <div class="mb-1 flex items-center justify-between">
            <span class="text-sm font-semibold">이 프로젝트만 고치기</span>
            <button
              :if={@prompt_overridden}
              phx-click="prompt_reset"
              class="btn btn-ghost btn-xs"
            >
              공용으로 되돌리기
            </button>
          </div>

          <form phx-submit="prompt_save">
            <textarea
              name="body"
              rows="16"
              class="textarea textarea-bordered w-full font-mono text-xs"
            >{@prompt_body}</textarea>
            <button type="submit" class="btn btn-sm mt-2">이 프로젝트 전용으로 저장</button>
          </form>
          <div class="mt-1 text-xs opacity-60">
            여기서 고치면 이 프로젝트만 바뀐다. 전체를 바꾸려면
            <.link navigate={~p"/prompts"} class="link">프롬프트</.link> 에서 고친다.
          </div>
        </div>
      </div>

      <h2 class="mt-8 mb-2 text-lg font-semibold">언어판</h2>
      <p class="mb-2 text-sm text-base-content/60">
        CLEAN 이미지에는 글자가 없으므로 언어판은 그걸 그대로 쓴다. INFO 와 나레이션만 새로 만들면 된다.
      </p>

      <div :if={@project.variant_of_id} class="alert alert-info py-2 text-sm">
        이 프로젝트는 <.link navigate={~p"/projects/#{@project.variant_of_id}"} class="link">원본</.link>
        의 {Projects.language_label(@project.language)} 판입니다.
      </div>

      <div :if={is_nil(@project.variant_of_id)}>
        <div :if={@variants != []} class="mb-2 flex flex-wrap gap-2">
          <.link
            :for={v <- @variants}
            navigate={~p"/projects/#{v.id}"}
            class="badge badge-lg badge-outline"
          >
            {Projects.language_label(v.language)} · {v.status}
          </.link>
        </div>

        <form phx-submit="make_variant" class="flex flex-wrap items-end gap-2">
          <label class="form-control">
            <span class="label-text text-xs">언어</span>
            <select name="language" class="select select-bordered select-sm">
              <option :for={{code, label} <- @languages} value={code} disabled={code == @project.language}>
                {label}{if code == @project.language, do: " (원본)", else: ""}
              </option>
            </select>
          </label>

          <label class="form-control">
            <span class="label-text text-xs">보이스</span>
            <select name="voice_slug" class="select select-bordered select-sm">
              <option value="">원본과 같게</option>
              <option :for={v <- @voices} value={v.slug}>{v.display_name} ({v.lang})</option>
            </select>
          </label>

          <button type="submit" class="btn btn-sm">언어판 만들기</button>
        </form>
      </div>

      <h2 class="mt-8 mb-2 text-lg font-semibold">컨택트시트</h2>
      <p class="mb-4 text-sm text-base-content/60">
        Flow 파일명은 내용과 무관하다. 그림을 보고 순서가 맞는지 확인하고, 틀렸으면 장면을 바꾼다.
      </p>

      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th class="w-16">장면</th>
              <th class="w-64">대본 구간</th>
              <th :for={kind <- ~w(clean info clip)}>{String.upcase(kind)}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={scene <- @scenes} class="align-top">
              <td>
                <div class="font-mono font-semibold">{pad(scene.scene_no)}</div>
                <div class="text-xs text-base-content/60">{scene.purpose}</div>
                <div class="text-xs text-base-content/60">{fmt(scene.target_sec)}s</div>
              </td>
              <td class="text-sm">
                <div>{Map.get(@segments, scene.id, "—")}</div>
                <div :if={scene.expected_labels != []} class="mt-1 text-xs text-base-content/60">
                  라벨: {Enum.join(scene.expected_labels, " → ")}
                </div>
              </td>
              <td :for={kind <- ~w(clean info clip)}>
                <.asset_cell asset={get_in(@by_scene, [scene.id, kind])} scenes={@scenes} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@unassigned != []} class="mt-8">
        <h2 class="mb-2 text-lg font-semibold text-warning">
          어느 장면에도 못 붙은 파일 {length(@unassigned)}개
        </h2>
        <div class="flex flex-wrap gap-3">
          <div :for={asset <- @unassigned} class="w-48">
            <.asset_cell asset={asset} scenes={@scenes} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :asset, :any, default: nil
  attr :scenes, :list, required: true

  defp asset_cell(%{asset: nil} = assigns) do
    ~H"""
    <div class="flex h-24 w-40 items-center justify-center rounded border border-dashed border-base-300 text-xs text-base-content/40">
      없음
    </div>
    """
  end

  defp asset_cell(assigns) do
    ~H"""
    <div class="w-40">
      <img
        src={~p"/assets/#{@asset.id}/preview"}
        alt={@asset.source_filename}
        loading="lazy"
        class="h-24 w-40 rounded border border-base-300 object-cover"
      />
      <div class="mt-1 truncate font-mono text-[10px] text-base-content/60" title={@asset.source_filename}>
        {@asset.source_filename}
      </div>
      <div class="flex items-center gap-1">
        <span class={["badge badge-xs", confidence_class(@asset.order_confidence)]}>
          {fmt(@asset.order_confidence)}
        </span>
        <button
          :if={@asset.status != "approved"}
          phx-click="approve"
          phx-value-asset_id={@asset.id}
          class="btn btn-ghost btn-xs"
        >
          확정
        </button>
        <span :if={@asset.status == "approved"} class="text-[10px] text-success">확정됨</span>
      </div>
      <form phx-change="reassign">
        <input type="hidden" name="asset_id" value={@asset.id} />
        <select name="scene_id" class="select select-xs mt-1 w-full">
          <option value="">— 장면 없음 —</option>
          <option :for={s <- @scenes} value={s.id} selected={s.id == @asset.scene_id}>
            {pad(s.scene_no)}번
          </option>
        </select>
      </form>
    </div>
    """
  end

  defp confidence_class(c) when is_float(c) do
    cond do
      c >= 0.9 -> "badge-success"
      Mapping.low_confidence?(c) -> "badge-error"
      true -> "badge-warning"
    end
  end

  defp confidence_class(_), do: "badge-ghost"

  defp format_check(true), do: "통과"
  defp format_check(false), do: "실패"
  defp format_check(other), do: to_string(other)

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
  defp fmt(nil), do: "-"
  defp fmt(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 2)
  defp fmt(n), do: to_string(n)
end