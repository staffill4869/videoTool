defmodule VideoToolWeb.VoiceLive do
  @moduledoc """
  목소리 고르는 화면.

  나레이션은 힉스필드(ElevenLabs)로 만들고, 어떤 목소리로 만들지는 `voice_id` 하나로 정해진다.
  전에는 그 목록이 손으로 넣은 17개뿐이라 실제로 쓸 수 있는 113개 중 대부분이 화면에
  안 보였다. 여기서 들어 보고 고르면 된다.

  **서버는 힉스필드를 부르지 않는다.** 목록과 미리듣기 주소는 에이전트가 `list_voices` 로
  받아 `priv/repo/voice_previews.exs` 에 넣어 둔 값이다. 목소리가 늘면 그 파일에 추가한다.
  """
  use VideoToolWeb, :live_view

  alias VideoTool.Presets

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(q: "", gender: "all", page_title: "목소리")
     |> load()}
  end

  defp load(socket) do
    voices = Presets.list_voices()
    assign(socket, all: voices, shown: filter(voices, socket.assigns[:q], socket.assigns[:gender]))
  end

  # 성별은 display_name 끝에 "— 남성 / — 여성" 으로 들어 있다. 따로 칼럼을 두지 않았다.
  defp gender_of(%{display_name: name}) do
    cond do
      String.contains?(name, "남성") -> "m"
      String.contains?(name, "여성") -> "f"
      true -> "?"
    end
  end

  defp short_name(%{display_name: name}), do: name |> String.split("—") |> List.first() |> String.trim()

  defp filter(voices, q, gender) do
    q = String.downcase(q || "")

    voices
    |> Enum.filter(fn v ->
      (gender in [nil, "all"] or gender_of(v) == gender) and
        (q == "" or String.contains?(String.downcase(v.display_name), q) or
           String.contains?(String.downcase(v.slug), q))
    end)
  end

  @impl true
  def handle_event("filter", params, socket) do
    q = params["q"] || socket.assigns.q
    gender = params["gender"] || socket.assigns.gender

    {:noreply,
     socket
     |> assign(q: q, gender: gender)
     |> then(&assign(&1, shown: filter(&1.assigns.all, q, gender)))}
  end

  def handle_event("set_default", %{"slug" => slug}, socket) do
    {:ok, voice} = Presets.fetch_voice(slug)
    Presets.set_default_voice(voice)

    {:noreply,
     socket
     |> put_flash(:info, "#{short_name(voice)} 를 기본 목소리로 정했습니다")
     |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:voices}>
      <div class="space-y-4">
        <div>
          <h1 class="text-2xl font-bold">목소리</h1>
          <p class="mt-1 text-sm text-base-content/70">
            나레이션에 쓸 목소리. 들어 보고 고르면 된다 — 고른 것은 대본 길이 계산의 기준이 되고,
            음성을 만들 때 <code class="font-mono text-xs">voice_id</code> 로 넘어간다.
          </p>
        </div>

        <form phx-change="filter" class="flex flex-wrap items-center gap-2">
          <input
            id="voice-q"
            type="search"
            name="q"
            value={@q}
            placeholder="이름으로 찾기"
            class="input input-sm input-bordered w-48"
            phx-debounce="200"
          />
          <div class="join">
            <label :for={{key, label} <- [{"all", "전체"}, {"m", "남성"}, {"f", "여성"}]} class="join-item">
              <input type="radio" name="gender" value={key} checked={@gender == key} class="hidden peer" />
              <span class={[
                "btn btn-sm",
                @gender == key && "btn-active"
              ]}>
                {label}
              </span>
            </label>
          </div>
          <span class="text-sm text-base-content/60">{length(@shown)} / {length(@all)}개</span>
        </form>

        <div class="grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
          <div
            :for={v <- @shown}
            class={[
              "rounded-lg border p-3",
              v.is_default && "border-primary bg-primary/5",
              !v.is_default && "border-base-300"
            ]}
          >
            <div class="flex items-baseline gap-2">
              <span class="font-semibold">{short_name(v)}</span>
              <span class="text-xs text-base-content/60">
                {if gender_of(v) == "m", do: "남성", else: "여성"}
              </span>
              <span :if={v.is_default} class="badge badge-primary badge-sm">기본</span>
              <span :if={v.sample_count > 0} class="ml-auto text-xs text-base-content/50">
                실측 {Float.round(v.chars_per_sec, 1)}자/초
              </span>
            </div>

            <audio :if={v.preview_url != ""} controls preload="none" src={v.preview_url} class="mt-2 w-full">
            </audio>
            <div :if={v.preview_url == ""} class="mt-2 text-xs text-base-content/50">
              미리듣기 없음
            </div>

            <div class="mt-2 flex items-center gap-2">
              <code class="min-w-0 flex-1 truncate font-mono text-[11px] text-base-content/60">
                {v.voice_id}
              </code>
              <button
                :if={!v.is_default}
                type="button"
                phx-click="set_default"
                phx-value-slug={v.slug}
                class="btn btn-ghost btn-xs"
              >
                기본으로
              </button>
            </div>
          </div>
        </div>

        <p :if={@shown == []} class="py-8 text-center text-sm text-base-content/60">
          찾는 목소리가 없습니다.
        </p>

        <div class="border-t border-base-300 pt-3 text-xs text-base-content/50">
          목록은 힉스필드 프리셋이다. 내 목소리를 복제해 쓰려면 힉스필드
          <code class="font-mono">create_voice</code> 로 녹음·업로드해야 한다 — 채팅 첨부는 안 되고
          그 창에서 파일을 다시 골라야 한다.
        </div>
      </div>
    </Layouts.app>
    """
  end
end
