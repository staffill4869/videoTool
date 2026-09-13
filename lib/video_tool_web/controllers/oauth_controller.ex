defmodule VideoToolWeb.OAuthController do
  @moduledoc """
  OAuth 콜백. 구글 동의 화면에서 돌아오는 곳이다.

  데스크톱 앱 클라이언트는 루프백 주소로 돌아올 수 있어서 `http://localhost:4300/...` 을 쓴다.
  """
  use VideoToolWeb, :controller

  alias VideoTool.Publishing.GoogleOAuth

  def google_callback(conn, %{"code" => code, "state" => state}) do
    case GoogleOAuth.complete(code, state) do
      {:ok, channel} ->
        conn
        |> put_flash(:info, "#{channel.display_name} 연결됐습니다.")
        |> redirect(to: ~p"/settings")

      {:error, reason} ->
        conn |> put_flash(:error, reason) |> redirect(to: ~p"/settings")
    end
  end

  # 사용자가 동의 화면에서 취소하면 code 없이 error 만 온다.
  def google_callback(conn, %{"error" => error}) do
    conn
    |> put_flash(:error, "구글에서 거절됐습니다: #{error}")
    |> redirect(to: ~p"/settings")
  end

  def google_callback(conn, _params) do
    conn |> put_flash(:error, "잘못된 콜백입니다.") |> redirect(to: ~p"/settings")
  end
end