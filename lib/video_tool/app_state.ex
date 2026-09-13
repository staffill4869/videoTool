defmodule VideoTool.AppState do
  @moduledoc """
  앱 전역 상태. 지금은 MCP 가 언제 붙었는지를 담는다.

  메모리에만 두지 않는 이유: 서버를 재시작할 때마다 "연결한 적 없음" 이 되어
  사용자를 다시 안내 화면에 가둔다.
  """

  import Ecto.Query
  alias VideoTool.Repo

  @mcp_key "mcp_last_seen"
  # 이보다 오래 조용하면 "지금은 안 붙어 있다" 로 본다.
  @fresh_seconds 300

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:key, :string, []}
    schema "app_state" do
      field :value, :map, default: %{}
      timestamps(type: :utc_datetime)
    end
  end

  def get(key) do
    case Repo.get(Row, key) do
      nil -> nil
      row -> row.value
    end
  end

  def put(key, value) when is_map(value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(
      %Row{key: key, value: value, inserted_at: now, updated_at: now},
      on_conflict: [set: [value: value, updated_at: now]],
      conflict_target: :key
    )
  end

  @doc "MCP 클라이언트가 붙었다고 기록한다. MCPController 가 부른다."
  def mcp_seen(client_info) do
    put(@mcp_key, %{
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "client" => client_name(client_info),
      "version" => client_version(client_info)
    })
  end

  defp client_name(%{"name" => name}), do: name
  defp client_name(_), do: "unknown"

  defp client_version(%{"version" => version}), do: version
  defp client_version(_), do: nil

  @doc "살아있다는 신호만 갱신한다. 클라이언트 정보는 그대로 둔다."
  def touch_mcp do
    existing = get(@mcp_key) || %{}
    put(@mcp_key, Map.put(existing, "at", DateTime.utc_now() |> DateTime.to_iso8601()))
  end

  @doc """
  MCP 연결 상태.

    * `:never`     — 한 번도 붙은 적이 없다
    * `:connected` — 최근에 붙었다
    * `:stale`     — 붙은 적은 있지만 한동안 조용하다
  """
  def mcp_status do
    case get(@mcp_key) do
      nil ->
        %{state: :never, at: nil, client: nil}

      %{"at" => at} = value ->
        seen = parse(at)

        state =
          cond do
            is_nil(seen) -> :never
            DateTime.diff(DateTime.utc_now(), seen) <= @fresh_seconds -> :connected
            true -> :stale
          end

        %{state: state, at: seen, client: value["client"], version: value["version"]}
    end
  end

  @doc "한 번이라도 붙은 적이 있는가. 안내 화면을 계속 띄울지 판단한다."
  def mcp_ever_connected?, do: mcp_status().state != :never

  @skip_key "mcp_gate_skipped"

  @doc """
  안내 화면을 건너뛴다고 기록한다.

  세션이 아니라 앱 상태에 남기는 이유: LiveView 의 `on_mount` 는 세션에 쓸 수 없고,
  URL 파라미터로 들고 다니면 링크를 한 번만 눌러도 사라진다.
  1인용 로컬 앱이라 전역으로 둬도 무방하다.
  """
  def skip_mcp_gate do
    put(@skip_key, %{"at" => DateTime.utc_now() |> DateTime.to_iso8601()})
  end

  def mcp_gate_skipped?, do: not is_nil(get(@skip_key))

  @doc "다시 안내 화면을 보고 싶을 때."
  def unskip_mcp_gate, do: Repo.delete_all(from r in Row, where: r.key == ^@skip_key)

  defp parse(nil), do: nil

  defp parse(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  _ = from(r in Row, select: r)
end