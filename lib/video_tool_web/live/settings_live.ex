defmodule VideoToolWeb.SettingsLive do
  @moduledoc """
  설정. 자격증명을 넣고, 구글 계정을 연결하고, 이 PC 에서 무엇이 준비됐는지 본다.

  값은 화면에서 넣어도 `.env` 를 고치지 않는다 — DPAPI 로 암호화해 파일에 둔다.
  넣은 값은 다시 보여주지 않는다 (앞뒤 몇 글자만). 화면을 켜둔 채 자리를 비우는 일이 있다.
  """
  use VideoToolWeb, :live_view

  alias VideoTool.{Publishing, Settings}
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
      channels: Publishing.list_channels(),
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

  def handle_event("connect", %{"slug" => slug}, socket) do
    case GoogleOAuth.authorize_url(slug) do
      {:ok, url} ->
        # 구글 동의 화면으로 보낸다. 돌아오면 콜백이 토큰을 저장한다.
        {:noreply, redirect(socket, external: url)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("disconnect", %{"slug" => slug}, socket) do
    {:ok, channel} = Publishing.fetch_channel(slug)
    {:ok, _} = GoogleOAuth.disconnect(channel)
    {:noreply, socket |> put_flash(:info, "#{channel.display_name} 연결을 끊었습니다") |> load()}
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

      <h2 class="mt-8 mb-2 text-lg font-semibold">채널 로그인</h2>

      <div class="mb-3 rounded border border-base-300 bg-base-200 p-3 text-sm">
        GCP 의 <strong>승인된 리디렉션 URI</strong> 에 이걸 그대로 넣어야 합니다 (설정이 끝난 뒤에도 필요합니다):
        <code class="ml-1 font-mono select-all">{@redirect_uri}</code>
        <div class="mt-1 text-xs opacity-60">
          애플리케이션 유형은 <strong>웹 애플리케이션</strong>. 고정 포트로 도는 로컬 서버라 이쪽이 맞습니다.
          동의 화면이 "테스트" 상태면 refresh token 이 7일 뒤 만료됩니다.
        </div>
      </div>

      <div :if={not @oauth_ready} class="alert alert-info text-sm">
        <div>
          <div class="font-semibold">OAuth 클라이언트를 먼저 넣어야 로그인 버튼이 열립니다</div>
          <ol class="mt-1 list-decimal pl-5">
            <li>GCP → 사용자 인증 정보 → OAuth 클라이언트 ID → <strong>데스크톱 앱</strong></li>
            <li>OAuth 동의 화면에서 본인 계정을 <strong>테스트 사용자</strong>로 등록 (심사 없이 쓸 수 있다)</li>
            <li>위 자격증명 칸에 ID 와 시크릿을 넣기</li>
          </ol>
          <div class="mt-2">
            승인된 리디렉션 URI 에 이걸 넣으세요:
            <code class="font-mono">{@redirect_uri}</code>
          </div>
        </div>
      </div>

      <div class="mt-3 grid gap-3 md:grid-cols-3">
        <div :for={c <- @channels} class="card bg-base-200">
          <div class="card-body gap-2 p-3">
            <div class="flex items-start justify-between">
              <div>
                <div class="text-sm font-medium">{c.display_name}</div>
                <div class="font-mono text-xs opacity-60">{c.slug} · {c.platform}</div>
              </div>
              <span class={["badge badge-sm", (Publishing.Channel.token_valid?(c) && "badge-success") || "badge-ghost"]}>
                {(Publishing.Channel.token_valid?(c) && "연결됨") || "미연결"}
              </span>
            </div>

            <div :if={c.token_expires_at} class="text-xs opacity-60">
              토큰 만료 {Calendar.strftime(c.token_expires_at, "%m-%d %H:%M")} (UTC) · 자동 갱신됨
            </div>

            <div class="flex gap-2">
              <button
                :if={c.platform == "youtube" and @oauth_ready}
                phx-click="connect"
                phx-value-slug={c.slug}
                class="btn btn-primary btn-xs"
              >
                구글로 로그인
              </button>
              <button
                :if={Publishing.Channel.token_valid?(c)}
                phx-click="disconnect"
                phx-value-slug={c.slug}
                class="btn btn-ghost btn-xs"
              >
                연결 끊기
              </button>
              <span :if={c.platform == "instagram"} class="text-xs opacity-60">
                인스타는 Meta 앱 검수가 먼저다 (6주차)
              </span>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end