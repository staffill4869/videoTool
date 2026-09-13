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
          "prompt" => "consent",
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
         {:ok, updated} <- store(channel, tokens) do
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

      Publishing.update_channel(channel, %{token_expires_at: expires_at})
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
        {:ok, _} = store(channel, Map.put(tokens, "refresh_token", refresh_token))
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