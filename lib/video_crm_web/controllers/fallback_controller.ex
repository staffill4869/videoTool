defmodule VideoCRMWeb.FallbackController do
  @moduledoc """
  API 액션이 `{:error, _}` 를 돌려줬을 때의 처리.

  **컨트롤러 자신을 action_fallback 으로 쓰면 안 된다.** 컨트롤러에는 이미 Plug 의 `call/2` 가
  있어서, 같은 이름의 절을 더하면 그걸 덮어쓰고 모든 액션이 FunctionClauseError 로 죽는다.
  (실제로 그렇게 만들었다가 API 전체가 500 이 났다.)
  """
  use VideoCRMWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn |> put_status(:unprocessable_entity) |> json(%{ok: false, errors: errors(changeset)})
  end

  def call(conn, {:error, reason}) when is_binary(reason) do
    conn |> put_status(:not_found) |> json(%{ok: false, error: reason})
  end

  def call(conn, {:error, reason}) do
    conn |> put_status(:unprocessable_entity) |> json(%{ok: false, error: inspect(reason)})
  end

  def call(conn, nil) do
    conn |> put_status(:not_found) |> json(%{ok: false, error: "찾을 수 없습니다"})
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end