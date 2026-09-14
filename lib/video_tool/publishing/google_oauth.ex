defmodule VideoTool.Publishing.GoogleOAuth do
  @moduledoc """
  구글 계정 연결. 유튜브 업로드에 필요하다.

  흐름:
    1. 인증창    GET  https://accounts.google.com/o/oauth2/v2/auth
    2. 콜백      GET  http://localhost:4300/oauth/google/callback?code=...&state=...
    3. 코드교환  POST https://oauth2.googleapis.com/token  → access_token(1시간) + refresh_token
    4. 저장      토큰은 DPAPI 로, 만료시각만 DB 로

  **state 는 DB 없이 `Phoenix.Token` 서명으로 처리한다** (10분 유효).
  별도 저장소가 필요 없고 위조도 불가능하다.

  `refresh_token` 은 **처음 동의할 때 한 번만** 내려온다. 그래서 `access_type=offline` 과
  `prompt=consent` 를 함께 준다 — 재연결할 때 refresh_token 이 안 와서 하루 만에 끊기는 일이 흔하다.

  client_id·client_secret 이 없으면 `configured?/0` 가 false 이고 화면에서 연결 버튼이 잠긴다.
  OAuth 를 안 붙여도 앱은 그대로 돈다.
  """

  require Logger

  alias VideoTool.{Credentials, Publishing, Settings}

  @authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @state_salt "google_oauth_state"
  @state_max_age 600

  # 실제로 쓰는 것만 넣는다. 과다 스코프는 심사 반려 사유이고,
  # 스코프는 인증 시점에 토큰에 박히므로 나중에 늘리면 재연결이 필요하다.
  @scopes [
    "https://www.googleapis.com/auth/youtube.upload",
    "https://www.googleapis.com/auth/youtube.force-ssl"
  ]

  def configured? do
    Settings.set?(:google_client_id) and Settings.set?(:google_client_secret)
  end

  def redirect_uri do
    Application.get_env(:video_tool, :google_redirect_uri) ||
      "http://localhost:4300/oauth/google/callback"
  end

  def scopes, do: @scopes

  @doc "인증창 URL. 채널 slug 를 state 에 서명해 담아 콜백에서 되찾는다."
  def authorize_url(channel_slug) do
    if configured?() do
      state = Phoenix.Token.sign(VideoToolWeb.Endpoint, @state_salt, channel_slug)

      query =
        URI.encode_query(%{
          "client_id" => Settings.get(:google_client_id),
          "redirect_uri" => redirect_uri(),
          "response_type" => "code",
          "scope" => Enum.join(@scopes, " "),
          "access_type" => "offline",
          # consent 만 주면 계정·채널 선택창을 건너뛰고 **직전에 쓰던 채널**로 그냥 넘어간다.
          # 브랜드 계정을 관리하고 있어도 목록을 볼 기회 자체가 없어진다 —
          # 실측: 관리 중인 채널이 둘 있는데도 선택창이 안 떠서 개인 채널에 붙었다.
          "prompt" => "select_account consent",
          "include_granted_scopes" => "true",
          "state" => state
        })

      {:ok, @authorize_url <> "?" <> query}
    else
      {:error, "구글 OAuth 클라이언트가 설정돼 있지 않습니다. 설정 화면에서 ID 와 시크릿을 넣으세요."}
    end
  end

  @doc "콜백에서 받은 code 를 토큰으로 바꾸고 저장한다."
  def complete(code, state) do
    with {:ok, channel_slug} <- verify_state(state),
         {:ok, channel} <- Publishing.fetch_channel(channel_slug),
         {:ok, tokens} <- exchange(code),
         {:ok, updated} <- store(channel, tokens),
         {:ok, updated} <- reject_duplicate(updated) do
      {:ok, updated}
    end
  end

  defp verify_state(state) do
    case Phoenix.Token.verify(VideoToolWeb.Endpoint, @state_salt, state, max_age: @state_max_age) do
      {:ok, slug} -> {:ok, slug}
      {:error, :expired} -> {:error, "인증 요청이 만료됐습니다 (10분). 다시 시도하세요."}
      {:error, _} -> {:error, "인증 요청을 확인할 수 없습니다."}
    end
  end

  defp exchange(code) do
    body = %{
      "code" => code,
      "client_id" => Settings.get(:google_client_id),
      "client_secret" => Settings.get(:google_client_secret),
      "redirect_uri" => redirect_uri(),
      "grant_type" => "authorization_code"
    }

    case Req.post(@token_url, form: body, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: %{"access_token" => _} = tokens}} -> {:ok, tokens}
      {:ok, %{status: status, body: body}} -> {:error, "토큰 교환 실패 (#{status}): #{describe(body)}"}
      {:error, reason} -> {:error, "토큰 교환 호출 실패: #{inspect(reason)}"}
    end
  end

  defp store(channel, tokens) do
    ref = channel.credential_ref

    payload =
      Jason.encode!(%{
        "access_token" => tokens["access_token"],
        # 재연결에서 refresh_token 이 안 오면 기존 것을 잃지 않게 유지한다.
        "refresh_token" => tokens["refresh_token"] || existing_refresh(ref),
        "scope" => tokens["scope"],
        "obtained_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    with {:ok, _} <- Credentials.put(ref, payload) do
      expires_at =
        DateTime.utc_now()
        |> DateTime.add(tokens["expires_in"] || 3600, :second)
        |> DateTime.truncate(:second)

      # 어느 유튜브 채널에 붙었는지 적어 둔다. 조회가 안 되면 만료시각만 갱신한다.
      # **중복 검사는 여기서 하지 않는다.** 이 함수는 한 시간마다 도는 토큰 갱신도 함께
      # 타는데, 갱신은 늘 같은 계정을 돌려주므로 이미 겹쳐 있는 행이 있으면 멀쩡한
      # 갱신까지 전부 막힌다 (실측: /series 가 통째로 500). 검사는 사람이 처음 연결하는
      # `connect/2` 에서만 한다.
      case whoami(tokens["access_token"]) do
        {:ok, id, title} ->
          Publishing.update_channel(channel, %{
            token_expires_at: expires_at,
            account_id: "#{id}|#{title}"
          })

        :error ->
          Publishing.update_channel(channel, %{token_expires_at: expires_at})
      end
    end
  end

  # 사람이 "구글로 로그인" 을 눌러 새로 붙일 때만 탄다.
  #
  # `videos.insert` 에는 채널을 지정하는 항목이 없다 — 토큰이 곧 채널이다. 그래서 두 칸이
  # 같은 계정에 연결되면 "시리즈마다 다른 채널" 이 말만 그렇고 전부 한 곳으로 간다.
  # 실제로 네 칸이 같은 채널을 물어 13편이 한 채널에 쌓였다.
  defp reject_duplicate(channel) do
    case Publishing.channel_conflicts(channel) do
      [] ->
        {:ok, channel}

      taken ->
        title = channel.account_id |> String.split("|") |> List.last()

        # 연결을 되돌린다. 토큰을 남겨 두면 화면에는 "연결됨" 으로 보인다.
        Credentials.delete(channel.credential_ref)
        Publishing.update_channel(channel, %{token_expires_at: nil, account_id: ""})

        {:error,
         "'#{title}' 은(는) 이미 #{Enum.map_join(taken, ", ", & &1.display_name)} 에 " <>
           "연결돼 있습니다. 한 유튜브 채널은 한 칸에만 연결할 수 있습니다 — " <>
           "칸마다 다른 채널을 고르거나, 먼저 저쪽 연결을 끊으세요."}
    end
  end

  @doc "이 토큰이 어느 유튜브 채널 것인지 읽기만 한다 (저장하지 않는다)."
  def whoami(access_token) when is_binary(access_token) do
    url = "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true"

    case Req.get(url, auth: {:bearer, access_token}, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"items" => [%{"id" => id, "snippet" => snip} | _]}}} ->
        {:ok, id, snip["title"] || ""}

      other ->
        Logger.warning("연결된 유튜브 채널을 못 읽었습니다: #{inspect(other)}")
        :error
    end
  rescue
    e ->
      Logger.warning("연결된 유튜브 채널 조회 실패: #{inspect(e)}")
      :error
  end

  def whoami(_), do: :error

  @doc """
  이 토큰이 어느 유튜브 채널 것인지 읽어 `account_id` 에 적는다.

  돌려주는 값은 쓰지 않는다 — 부수적인 일이라 실패해도 연결을 되돌리지 않는다.
  """
  def identify(channel, access_token) do
    case whoami(access_token) do
      {:ok, id, title} ->
        Publishing.update_channel(channel, %{account_id: "#{id}|#{title}"})
        {:ok, id, title}

      :error ->
        :error
    end
  end

  defp existing_refresh(ref) do
    with {:ok, raw} <- Credentials.get(ref),
         {:ok, %{"refresh_token" => token}} <- Jason.decode(raw) do
      token
    else
      _ -> nil
    end
  end

  @doc "저장된 access_token. 만료됐으면 refresh_token 으로 새로 받는다."
  def access_token(channel) do
    with {:ok, raw} <- Credentials.get(channel.credential_ref),
         {:ok, stored} <- Jason.decode(raw) do
      if Publishing.Channel.token_valid?(channel) do
        {:ok, stored["access_token"]}
      else
        refresh(channel, stored["refresh_token"])
      end
    else
      {:error, :not_found} -> {:error, "이 채널은 아직 연결되지 않았습니다."}
      error -> {:error, "토큰을 읽지 못했습니다: #{inspect(error)}"}
    end
  end

  defp refresh(_channel, nil), do: {:error, "refresh_token 이 없습니다. 채널을 다시 연결하세요."}

  defp refresh(channel, refresh_token) do
    body = %{
      "refresh_token" => refresh_token,
      "client_id" => Settings.get(:google_client_id),
      "client_secret" => Settings.get(:google_client_secret),
      "grant_type" => "refresh_token"
    }

    case Req.post(@token_url, form: body, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: %{"access_token" => token} = tokens}} ->
        # 저장이 실패해도 토큰 자체는 쓸 수 있다. 여기서 터뜨리면 상태 화면이 통째로 죽는다.
        _ = store(channel, Map.put(tokens, "refresh_token", refresh_token))
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error, "토큰 갱신 실패 (#{status}): #{describe(body)}"}

      {:error, reason} ->
        {:error, "토큰 갱신 호출 실패: #{inspect(reason)}"}
    end
  end

  def disconnect(channel) do
    Credentials.delete(channel.credential_ref)
    Publishing.update_channel(channel, %{token_expires_at: nil})
  end

  defp describe(%{"error_description" => message}), do: message
  defp describe(%{"error" => message}) when is_binary(message), do: message
  defp describe(body), do: body |> inspect() |> String.slice(0, 200)
end