defmodule VideoToolWeb.SeriesLive do
  @moduledoc """
  반복 제작 설정. 한 번 정해두면 간격마다 프로젝트가 하나씩 생긴다.

  **제작만 자동이고 발행은 아니다.** 만들어진 프로젝트는 대본이 빈 채로 대기하고,
  대본은 에이전트가 쓴다. 발행은 사람이 누를 때만 나간다.
  """
  use VideoToolWeb, :live_view

  alias VideoTool.{Presets, Projects, Series}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(editing: nil, form_error: nil) |> load()}
  end

  defp load(socket) do
    series = Series.list()

    assign(socket,
      series: series,
      colors: Series.color_map(series),
      styles: Presets.list_styles(),
      domains: Presets.list_domains(),
      voices: Presets.list_voices(),
      languages: Projects.language_names(),
      summary: VideoTool.Work.summary()
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
        # 만들기만 하면 대본이 빈 채로 서 있는다. 누른 사람은 "지금 만들어라" 라고
        # 누른 것이므로 대본을 쓸 에이전트까지 여기서 깨운다.
        message =
          case Series.kick_agent() do
            :ok -> "'#{project.title}' 을(를) 만들고 에이전트를 깨웠습니다. 대본부터 씁니다."
            {:error, why} -> "'#{project.title}' 을(를) 만들었습니다. 다만 #{why}"
          end

        {:noreply, socket |> put_flash(:info, message) |> load()}

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
                   interval_minutes max_pending voice_id subtitle_font))
    |> Map.put("languages", params["languages"] || ["ko"])
    # "09:00, 21:00" → ["09:00", "21:00"]. 빈 칸은 버린다.
    |> Map.put("run_times", split_times(params["run_times"]))
    |> Map.put("run_days", Enum.map(params["run_days"] || [], &String.to_integer/1))
    |> Map.put("style_id", resolve_style(params["style_name"]))
    |> Map.put("domain_id", resolve_domain(params["domain_name"]))
  end

  # 적어 넣은 이름이 목록에 있으면 그걸 쓰고, 없으면 그 이름으로 새로 만든다.
  # 빈 그림체를 만들면 프롬프트가 ⟨미설정⟩ 으로 렌더되므로, 이름을 실제 규칙에 꽂아 넣는다 —
  # 이름만 다르고 내용이 같으면 고른 의미가 없다. 세부는 /prompts 에서 다듬는다.
  defp resolve_style(nil), do: nil

  defp resolve_style(name) do
    name = String.trim(name)

    case Enum.find(Presets.list_styles(), &(&1.name == name)) do
      %{id: id} ->
        id

      nil ->
        case Presets.create_style_from_name(name) do
          {:ok, style} -> style.id
          {:error, _} -> nil
        end
    end
  end

  defp resolve_domain(nil), do: nil

  defp resolve_domain(name) do
    name = String.trim(name)

    case Enum.find(Presets.list_domains(), &(&1.name == name)) do
      %{id: id} ->
        id

      nil ->
        case Presets.create_domain_from_name(name) do
          {:ok, domain} -> domain.id
          {:error, _} -> nil
        end
    end
  end

  defp split_times(nil), do: []

  defp split_times(text) do
    text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  # 저장은 UTC 로 하지만 사람에게는 로컬로 보여준다. UTC 로 보여주면 9시간 어긋나 보인다.
  defp local_time(utc) do
    offset = NaiveDateTime.diff(NaiveDateTime.local_now(), NaiveDateTime.utc_now())
    utc |> DateTime.add(round(offset / 60) * 60, :second) |> Calendar.strftime("%m/%d %H:%M")
  end

  defp name_of(list, id) do
    case Enum.find(list, &(&1.id == id)) do
      nil -> ""
      row -> row.name
    end
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
        <%!-- 왼쪽 색 띠. /projects 에서 이 시리즈가 찍어낸 프로젝트에 같은 색이 붙는다.
              Tailwind 클래스가 아니라 인라인 style 인 이유: 색이 실행 시점에 정해져
              컴파일 때 클래스 이름을 알 수 없다 — JIT 가 만들어주지 못한다. --%>
        <div
          :for={s <- @series}
          class="card overflow-hidden bg-base-200"
          style={"border-left: 8px solid #{@colors[s.id]}"}
        >
          <div class="card-body gap-2 p-4">
            <div class="flex flex-wrap items-start justify-between gap-2">
              <div>
                <div class="flex items-center gap-2">
                  <span style={"display:inline-block;width:12px;height:12px;border-radius:9999px;background:#{@colors[s.id]}"}></span>
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
    assigns = assign(assigns, :s, if(assigns.editing == :new, do: %VideoTool.Series.Recipe{}, else: assigns.editing))

    ~H"""
    <form phx-submit="save" class="mt-6 card bg-base-200">
      <div class="card-body gap-4 p-4">
        <div class="font-semibold">{(@new? && "새 시리즈") || "시리즈 수정"}</div>
        <div :if={@error} class="alert alert-error py-2 text-sm">{@error}</div>

        <.section title="기본">
          <div class="grid gap-3 md:grid-cols-3">
            <.field label="이름">
              <input name="name" value={@s.name} required class="input input-bordered input-sm w-full" />
            </.field>
            <.field label="주제 브리프" hint="매 편의 기본 주제">
              <input
                name="topic_brief"
                value={@s.topic_brief}
                class="input input-bordered input-sm w-full"
              />
            </.field>
            <.field label="완성본 폴더">
              <input
                name="output_folder"
                value={@s.output_folder}
                class="input input-bordered input-sm w-full"
              />
            </.field>
          </div>
        </.section>

        <.section
          title="상시 프롬프트"
          hint={~s(매 편에 그대로 들어간다. "계속 하나의 프롬프트로 찍어낸다" 의 그 프롬프트)}
        >
          <textarea name="standing_prompt" rows="5" class="textarea textarea-bordered textarea-sm w-full font-mono text-xs">{@s.standing_prompt}</textarea>
        </.section>

        <.section title="제작 설정">
          <div class="grid gap-3 md:grid-cols-3">
            <%!-- select 가 아니라 datalist 다. 목록에서 고를 수도 있고, 없는 이름을 직접 쳐서
                  그 자리에서 만들 수도 있다. 만들려고 다른 화면으로 갔다 오게 하지 않는다. --%>
            <.field label="그림체" hint="목록에 없으면 직접 쓰면 새로 만들어진다">
              <input
                name="style_name"
                list="style-options"
                value={name_of(@styles, @s.style_id)}
                required
                placeholder="고르거나 직접 입력"
                class="input input-bordered input-sm w-full"
              />
              <datalist id="style-options">
                <option :for={x <- @styles} value={x.name}></option>
              </datalist>
            </.field>
            <.field label="장르" hint="목록에 없으면 직접 쓰면 새로 만들어진다">
              <input
                name="domain_name"
                list="domain-options"
                value={name_of(@domains, @s.domain_id)}
                required
                placeholder="고르거나 직접 입력"
                class="input input-bordered input-sm w-full"
              />
              <datalist id="domain-options">
                <option :for={x <- @domains} value={x.name}></option>
              </datalist>
            </.field>
            <.field label="보이스" hint="힉스필드 MCP 에서 들여온 목록">
              <select name="voice_id" class="select select-bordered select-sm w-full">
                <option :for={x <- @voices} value={x.id} selected={x.id == @s.voice_id}>
                  {x.display_name}
                </option>
              </select>
            </.field>
            <.field label="자막 폰트" hint="이 PC 에 깔린 폰트만">
              <select name="subtitle_font" class="select select-bordered select-sm w-full">
                <option value="" selected={@s.subtitle_font in [nil, ""]}>
                  기본 ({VideoTool.Presets.default_subtitle_font()})
                </option>
                <option
                  :for={{label, name} <- VideoTool.Presets.subtitle_fonts()}
                  value={name}
                  selected={name == @s.subtitle_font}
                >
                  {label}
                </option>
              </select>
            </.field>
            <.field label="화면비">
              <select name="aspect" class="select select-bordered select-sm w-full">
                <option :for={a <- ~w(16:9 9:16)} value={a} selected={a == @s.aspect}>{a}</option>
              </select>
            </.field>
            <.field label="목표 길이" hint="초">
              <input
                type="number"
                name="target_sec"
                value={@s.target_sec || 60}
                min="10"
                class="input input-bordered input-sm w-full"
              />
            </.field>
          </div>
        </.section>

        <.section
          title="보이스 미리듣기"
          hint="고르기 전에 들어보세요. 낭독 속도는 건드리지 않습니다 — 길이가 안 맞으면 대본을 고칩니다"
        >
          <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            <div
              :for={v <- @voices}
              :if={v.preview_url not in [nil, ""]}
              class="flex items-center gap-2 text-xs"
            >
              <span class="w-40 shrink-0 truncate" title={v.display_name}>{v.display_name}</span>
              <audio src={v.preview_url} controls preload="none" class="h-8 w-full"></audio>
            </div>
          </div>
        </.section>

        <.section title="언어" hint="첫 번째가 원본. 나머지는 CLEAN 이미지를 재사용하는 언어판이다">
          <div class="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4">
            <label
              :for={{code, label} <- @languages}
              class="flex items-center gap-2 text-xs cursor-pointer"
            >
              <input
                type="checkbox"
                name="languages[]"
                value={code}
                checked={code in (@s.languages || ["ko"])}
                class="checkbox checkbox-xs"
              />
              <span class="truncate">{label}</span>
            </label>
          </div>
        </.section>

        <.section title="자동 제작" hint="제작만 자동이고 발행은 사람이 누른다">
          <%!-- 시각 예약이 간격보다 우선한다. 둘을 함께 쓰면 언제 도는지 예측할 수 없어서다. --%>
          <div class="mb-3 grid gap-3 md:grid-cols-2">
            <.field label="시각 예약" hint="쉼표로 여러 개. 비우면 아래 간격을 쓴다">
              <input
                name="run_times"
                value={Enum.join(@s.run_times || [], ", ")}
                placeholder="09:00, 21:00"
                class="input input-bordered input-sm w-full font-mono"
              />
            </.field>
            <.field label="요일" hint="아무것도 안 고르면 매일">
              <div class="flex flex-wrap gap-2 pt-1">
                <label
                  :for={{n, label} <- [{1, "월"}, {2, "화"}, {3, "수"}, {4, "목"}, {5, "금"}, {6, "토"}, {7, "일"}]}
                  class="flex cursor-pointer items-center gap-1 text-xs"
                >
                  <input
                    type="checkbox"
                    name="run_days[]"
                    value={n}
                    checked={n in (@s.run_days || [])}
                    class="checkbox checkbox-xs"
                  />
                  {label}
                </label>
              </div>
            </.field>
          </div>

          <div :if={@s.next_run_at} class="mb-3 text-xs opacity-60">
            다음 실행: {local_time(@s.next_run_at)}
          </div>

          <div class="grid gap-3 md:grid-cols-3">
            <.field label="몇 분마다" hint="0 = 안 함 · 60=1시간 · 360=6시간 · 1440=하루">
              <input
                type="number"
                name="interval_minutes"
                value={@s.interval_minutes || 0}
                min="0"
                class="input input-bordered input-sm w-full"
              />
            </.field>
            <.field label="대기 상한" hint="쌓인 일이 이보다 많으면 새로 안 만든다">
              <input
                type="number"
                name="max_pending"
                value={@s.max_pending || 3}
                min="1"
                max="50"
                class="input input-bordered input-sm w-full"
              />
            </.field>
            <.field label="생성 경로">
              <select name="pipeline" class="select select-bordered select-sm w-full">
                <option value="ai" selected={@s.pipeline in [nil, "ai"]}>ai — 사람이 Flow 조작</option>
                <option value="flow_auto" selected={@s.pipeline == "flow_auto"}>
                  flow_auto — 브라우저 자동 조종
                </option>
              </select>
            </.field>
          </div>
        </.section>

        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary btn-sm">저장</button>
          <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">취소</button>
        </div>
      </div>
    </form>
    """
  end

  # 폼을 의미 단위로 묶는다. 칸이 20개 넘게 한 줄로 흐르면 뭘 고치는 중인지 놓친다.
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <fieldset class="rounded-lg border border-base-300 bg-base-100 px-4 pb-4 pt-2">
      <legend class="px-2 text-xs font-semibold opacity-70">{@title}</legend>
      <p :if={@hint} class="mb-3 text-xs opacity-50">{@hint}</p>
      {render_slot(@inner_block)}
    </fieldset>
    """
  end

  # 라벨을 칸 위에 올리고 폭을 w-full 로 통일한다.
  # 라벨을 옆에 두면 라벨 길이만큼 칸 시작점이 밀려서 줄마다 어긋난다.
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <label class="block">
      <span class="mb-1 block text-xs opacity-70">
        {@label}<span :if={@hint} class="ml-1 opacity-60">— {@hint}</span>
      </span>
      {render_slot(@inner_block)}
    </label>
    """
  end
end