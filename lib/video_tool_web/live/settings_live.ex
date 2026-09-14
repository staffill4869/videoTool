defmodule VideoToolWeb.SettingsLive do
  @moduledoc """
  설정. 자격증명을 넣고, 구글 계정을 연결하고, 이 PC 에서 무엇이 준비됐는지 본다.

  값은 화면에서 넣어도 `.env` 를 고치지 않는다 — DPAPI 로 암호화해 파일에 둔다.
  넣은 값은 다시 보여주지 않는다 (앞뒤 몇 글자만). 화면을 켜둔 채 자리를 비우는 일이 있다.
  """
  use VideoToolWeb, :live_view

  alias VideoTool.Settings
  alias VideoTool.Publishing.GoogleOAuth

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  defp load(socket) do
    assign(socket,
      status: Settings.status(),
      secrets:
        Enum.map(Settings.secrets(), fn {key, _ref, env, label, help} ->
          %{
            key: key,
            env: env,
            label: label,
            help: help,
            masked: Settings.masked(key),
            source: Settings.source(key)
          }
        end),
      oauth_ready: GoogleOAuth.configured?(),
      redirect_uri: GoogleOAuth.redirect_uri()
    )
  end

  # ── 이벤트 ──────────────────────────────────────────────────────

  @impl true
  def handle_event("save_secret", %{"key" => key, "value" => value}, socket) do
    name = String.to_existing_atom(key)

    case Settings.set(name, value) do
      {:ok, :cleared} -> {:noreply, socket |> put_flash(:info, "지웠습니다") |> load()}
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "저장했습니다") |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  # ── 화면 ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:settings}>
      <.header>
        설정
        <:subtitle>
          자격증명은 DB 에 넣지 않는다. Windows 자격증명(DPAPI)으로 암호화해 파일에 둔다.
        </:subtitle>
        <:actions>
          <.button phx-click="refresh" class="btn-ghost btn-sm">다시 확인</.button>
        </:actions>
      </.header>

      <h2 class="mt-6 mb-2 text-lg font-semibold">준비 상태</h2>
      <div class="grid gap-2 md:grid-cols-2 lg:grid-cols-3">
        <div :for={{_key, item} <- @status} class="card bg-base-200">
          <div class="card-body gap-1 p-3">
            <div class="flex items-center justify-between">
              <span class="text-sm font-medium">{item.label}</span>
              <span class={["badge badge-sm", (item.ready && "badge-success") || "badge-ghost"]}>
                {(item.ready && "준비됨") || "없음"}
              </span>
            </div>
            <div class="text-xs opacity-70">{item.enables}</div>
            <div :if={not item.ready} class="text-xs opacity-50">{item.hint}</div>
          </div>
        </div>
      </div>

      <h2 class="mt-8 mb-2 text-lg font-semibold">자격증명</h2>
      <p class="mb-3 text-sm text-base-content/60">
        넣으면 다시 보여주지 않는다. 비우고 저장하면 지워진다.
        <code class="font-mono">.env</code> 에 넣어도 되지만, 여기서 넣은 값이 이긴다.
      </p>

      <div class="space-y-3">
        <form :for={s <- @secrets} phx-submit="save_secret" class="card bg-base-200">
          <div class="card-body gap-2 p-3">
            <input type="hidden" name="key" value={s.key} />
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div>
                <span class="text-sm font-medium">{s.label}</span>
                <span class="ml-2 font-mono text-xs opacity-50">{s.env}</span>
              </div>
              <span :if={s.masked} class="flex items-center gap-2">
                <span class="badge badge-xs badge-ghost">{s.source}</span>
                <span class="font-mono text-xs text-success">{s.masked}</span>
              </span>
              <span :if={is_nil(s.masked)} class="text-xs opacity-50">미설정</span>
            </div>
            <div class="text-xs opacity-70">{s.help}</div>
            <div class="flex gap-2">
              <input
                type="password"
                name="value"
                placeholder={(s.masked && "새 값 (비우고 저장하면 삭제)") || "값을 붙여넣으세요"}
                autocomplete="off"
                class="input input-bordered input-sm flex-1 font-mono"
              />
              <button type="submit" class="btn btn-sm">저장</button>
            </div>
          </div>
        </form>
      </div>

      <div class="mt-8 rounded border border-base-300 bg-base-200 p-3 text-sm">
        <div class="font-semibold">채널 연결은 <a href="/series" class="link">반복 제작</a> 에서 합니다</div>
        <div class="mt-1 opacity-70">
          어느 시리즈가 어디로 올라가는지를 한 자리에서 보기 위해 시리즈 안으로 옮겼습니다.
          시리즈마다 <strong>채널</strong>·<strong>쇼츠</strong> 두 칸이 있고, 한 유튜브 채널은 한 칸에만 붙습니다.
        </div>
        <div class="mt-2 text-xs opacity-60">
          GCP 의 승인된 리디렉션 URI:
          <code class="font-mono select-all">{@redirect_uri}</code>
        </div>
      </div>

    </Layouts.app>
    """
  end
end