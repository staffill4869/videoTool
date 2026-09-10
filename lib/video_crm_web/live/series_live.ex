defmodule VideoCRMWeb.SeriesLive do
  @moduledoc """
  반복 제작 설정. 한 번 정해두면 간격마다 프로젝트가 하나씩 생긴다.

  **제작만 자동이고 발행은 아니다.** 만들어진 프로젝트는 대본이 빈 채로 대기하고,
  대본은 에이전트가 쓴다. 발행은 사람이 누를 때만 나간다.
  """
  use VideoCRMWeb, :live_view

  alias VideoCRM.{Presets, Projects, Series}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(editing: nil, form_error: nil) |> load()}
  end

  defp load(socket) do
    assign(socket,
      series: Series.list(),
      styles: Presets.list_styles(),
      domains: Presets.list_domains(),
      voices: Presets.list_voices(),
      languages: Projects.language_names(),
      summary: VideoCRM.Work.summary()
    )
  end

  # ── 이벤트 ──────────────────────────────────────────────────────

  @impl true
  def handle_event("new", _params, socket), do: {:noreply, assign(socket, editing: :new, form_error: nil)}

  def handle_event("edit", %{"id" => id}, socket) do
    {:ok, series} = Series.get(id)
    {:noreply, assign(socket, editing: series, form_error: nil)}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("save", params, socket) do
    attrs = normalize(params)

    result =
      case socket.assigns.editing do
        :new -> Series.create(attrs)
        series -> Series.update(series, attrs)
      end

    case result do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "저장했습니다") |> assign(editing: nil) |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form_error: format_errors(changeset))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    {:ok, series} = Series.get(id)
    {:ok, updated} = Series.update(series, %{"active" => not series.active})

    message =
      if updated.active,
        do: "'#{updated.name}' 켰습니다. #{updated.interval_minutes}분마다 만듭니다.",
        else: "'#{updated.name}' 껐습니다."

    {:noreply, socket |> put_flash(:info, message) |> load()}
  end

  def handle_event("run_now", %{"id" => id}, socket) do
    {:ok, series} = Series.get(id)

    case Series.spawn_project(series) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "'#{project.title}' 을(를) 만들었습니다. 대본은 에이전트가 씁니다.")
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, series} = Series.get(id)
    {:ok, _} = Series.delete(series)
    {:noreply, socket |> put_flash(:info, "지웠습니다. 만들어진 프로젝트는 남아 있습니다.") |> load()}
  end

  defp normalize(params) do
    params
    |> Map.take(~w(name topic_brief standing_prompt aspect target_sec pipeline output_folder
                   interval_minutes max_pending style_id domain_id voice_id))
    |> Map.put("languages", params["languages"] || ["ko"])
  end

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join(" · ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  # ── 화면 ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:series}>
      <.header>
        반복 제작
        <:subtitle>
          한 번 정해두면 간격마다 프로젝트가 생긴다. 제작만 자동이고 발행은 사람이 누른다.
        </:subtitle>
        <:actions>
          <.button phx-click="new" class="btn-primary btn-sm">새 시리즈</.button>
        </:actions>
      </.header>

      <div class="mt-4 flex flex-wrap gap-2 text-sm">
        <span class="badge badge-lg badge-ghost">대기 중인 일 {@summary.pending_jobs}건</span>
        <span class="badge badge-lg badge-ghost">도는 시리즈 {@summary.active_series}개</span>
        <span class="badge badge-lg badge-ghost">프로젝트 {@summary.projects}개</span>
      </div>

      <.form_panel
        :if={@editing}
        editing={@editing}
        styles={@styles}
        domains={@domains}
        voices={@voices}
        languages={@languages}
        error={@form_error}
      />

      <div :if={@series == []} class="mt-8 text-base-content/60">
        시리즈가 없습니다. <strong>새 시리즈</strong> 로 하나 만드세요 —
        그림체·언어·간격을 정해두면 계속 찍어냅니다.
      </div>

      <div class="mt-6 space-y-3">
        <div :for={s <- @series} class="card bg-base-200">
          <div class="card-body gap-2 p-4">
            <div class="flex flex-wrap items-start justify-between gap-2">
              <div>
                <div class="flex items-center gap-2">
                  <span class="font-semibold">{s.name}</span>
                  <span class={["badge badge-sm", (s.active && "badge-success") || "badge-ghost"]}>
                    {(s.active && "켜짐") || "꺼짐"}
                  </span>
                </div>
                <div class="mt-1 text-xs opacity-70">
                  {s.style.name} · {s.domain.name} · {s.voice.display_name} · {s.aspect} ·
                  {s.target_sec}초 · 언어 {Enum.join(s.languages || [], ", ")}
                </div>
                <div class="text-xs opacity-70">
                  {if s.interval_minutes > 0,
                    do: "#{s.interval_minutes}분마다 · 대기 상한 #{s.max_pending}",
                    else: "자동 생성 안 함 (수동으로만)"}
                  · 지금까지 {s.created_count}편 · 대기 {Series.pending_count(s.id)}건
                </div>
                <div :if={s.next_run_at && s.active} class="text-xs opacity-50">
                  다음 생성 {Calendar.strftime(s.next_run_at, "%m-%d %H:%M")} (UTC)
                </div>
                <div :if={s.last_error != ""} class="mt-1 text-xs text-warning">⚠ {s.last_error}</div>
              </div>

              <div class="flex flex-wrap gap-1">
                <button phx-click="run_now" phx-value-id={s.id} class="btn btn-xs">지금 하나</button>
                <button phx-click="toggle" phx-value-id={s.id} class="btn btn-xs">
                  {(s.active && "끄기") || "켜기"}
                </button>
                <button phx-click="edit" phx-value-id={s.id} class="btn btn-ghost btn-xs">수정</button>
                <button
                  phx-click="delete"
                  phx-value-id={s.id}
                  data-confirm={"'#{s.name}' 설정을 지웁니다. 이미 만들어진 프로젝트는 남습니다."}
                  class="btn btn-ghost btn-xs text-error"
                >
                  삭제
                </button>
              </div>
            </div>

            <div :if={s.standing_prompt != ""} class="mt-1">
              <div class="text-xs font-semibold opacity-60">상시 프롬프트</div>
              <pre class="mt-1 max-h-24 overflow-auto rounded bg-base-100 p-2 text-xs whitespace-pre-wrap">{s.standing_prompt}</pre>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :editing, :any, required: true
  attr :styles, :list, required: true
  attr :domains, :list, required: true
  attr :voices, :list, required: true
  attr :languages, :map, required: true
  attr :error, :any, default: nil

  defp form_panel(assigns) do
    assigns = assign(assigns, :new?, assigns.editing == :new)
    assigns = assign(assigns, :s, if(assigns.editing == :new, do: %VideoCRM.Series.Recipe{}, else: assigns.editing))

    ~H"""
    <form phx-submit="save" class="mt-6 card bg-base-200">
      <div class="card-body gap-3 p-4">
        <div class="font-semibold">{(@new? && "새 시리즈") || "시리즈 수정"}</div>
        <div :if={@error} class="alert alert-error py-2 text-sm">{@error}</div>

        <div class="grid gap-3 md:grid-cols-2">
          <label class="form-control">
            <span class="label-text text-xs">이름</span>
            <input name="name" value={@s.name} required class="input input-bordered input-sm" />
          </label>

          <label class="form-control">
            <span class="label-text text-xs">완성본 폴더</span>
            <input name="output_folder" value={@s.output_folder} class="input input-bordered input-sm" />
          </label>
        </div>

        <label class="form-control">
          <span class="label-text text-xs">주제 브리프 — 매 편의 기본 주제</span>
          <input name="topic_brief" value={@s.topic_brief} class="input input-bordered input-sm" />
        </label>

        <label class="form-control">
          <span class="label-text text-xs">
            상시 프롬프트 — 매 편에 그대로 들어간다. "계속 하나의 프롬프트로 찍어낸다" 의 그 프롬프트
          </span>
          <textarea name="standing_prompt" rows="4" class="textarea textarea-bordered textarea-sm font-mono text-xs">{@s.standing_prompt}</textarea>
        </label>

        <div class="grid gap-3 md:grid-cols-3">
          <label class="form-control">
            <span class="label-text text-xs">그림체</span>
            <select name="style_id" class="select select-bordered select-sm">
              <option :for={x <- @styles} value={x.id} selected={x.id == @s.style_id}>{x.name}</option>
            </select>
          </label>

          <label class="form-control">
            <span class="label-text text-xs">장르</span>
            <select name="domain_id" class="select select-bordered select-sm">
              <option :for={x <- @domains} value={x.id} selected={x.id == @s.domain_id}>{x.name}</option>
            </select>
          </label>

          <label class="form-control">
            <span class="label-text text-xs">보이스</span>
            <select name="voice_id" class="select select-bordered select-sm">
              <option :for={x <- @voices} value={x.id} selected={x.id == @s.voice_id}>
                {x.display_name}
              </option>
            </select>
          </label>
        </div>

        <div class="grid gap-3 md:grid-cols-4">
          <label class="form-control">
            <span class="label-text text-xs">화면비</span>
            <select name="aspect" class="select select-bordered select-sm">
              <option :for={a <- ~w(16:9 9:16)} value={a} selected={a == @s.aspect}>{a}</option>
            </select>
          </label>

          <label class="form-control">
            <span class="label-text text-xs">목표 길이(초)</span>
            <input
              type="number"
              name="target_sec"
              value={@s.target_sec || 60}
              min="10"
              class="input input-bordered input-sm"
            />
          </label>

          <label class="form-control">
            <span class="label-text text-xs">몇 분마다 (0 = 자동 안 함)</span>
            <input
              type="number"
              name="interval_minutes"
              value={@s.interval_minutes || 0}
              min="0"
              class="input input-bordered input-sm"
            />
          </label>

          <label class="form-control">
            <span class="label-text text-xs">대기 상한</span>
            <input
              type="number"
              name="max_pending"
              value={@s.max_pending || 3}
              min="1"
              max="50"
              class="input input-bordered input-sm"
            />
          </label>
        </div>

        <div>
          <div class="label-text mb-1 text-xs">
            언어 — 첫 번째가 원본. 나머지는 CLEAN 이미지를 재사용하는 언어판이다
          </div>
          <div class="flex flex-wrap gap-2">
            <label :for={{code, label} <- @languages} class="flex items-center gap-1 text-xs">
              <input
                type="checkbox"
                name="languages[]"
                value={code}
                checked={code in (@s.languages || ["ko"])}
                class="checkbox checkbox-xs"
              />
              {label}
            </label>
          </div>
        </div>

        <label class="form-control max-w-xs">
          <span class="label-text text-xs">생성 경로</span>
          <select name="pipeline" class="select select-bordered select-sm">
            <option value="ai" selected={@s.pipeline in [nil, "ai"]}>ai — 사람이 Flow 조작</option>
            <option value="flow_auto" selected={@s.pipeline == "flow_auto"}>
              flow_auto — 브라우저 자동 조종
            </option>
          </select>
        </label>

        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary btn-sm">저장</button>
          <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">취소</button>
        </div>
      </div>
    </form>
    """
  end
end