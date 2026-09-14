defmodule VideoTool.Activity do
  @moduledoc """
  누가 이 서버를 몰고 있는지 알 수 있게, 들어온 MCP 도구 호출을 남긴다.

  왜: 무인 루프를 모는 주체가 여럿이다 — Windows 예약(run-agent.ps1), Cowork 예약,
  사람이 붙은 Claude Code. 그런데 "작업 중" 판단을 `.agent.lock`(run-agent.ps1 만 만든다)
  으로 해서, Cowork 가 한창 일하는 중에도 화면에는 "쉬는 중" 으로 보였다.

  도구 호출은 **누가 불렀든 서버를 지난다.** 그래서 이게 유일하게 믿을 수 있는 신호다.

  최근 것 몇 개만 `app_state` 한 행에 담는다. 호출마다 행을 만들면 금방 수만 건이 되는데,
  알고 싶은 건 "지금 움직이고 있나" 지 전수 감사 로그가 아니다.
  """

  import Ecto.Query

  alias VideoTool.Repo

  @key "mcp_activity"
  @keep 20

  # 상태를 보는 도구까지 세면 화면이 스스로를 켜 놓은 것처럼 보인다.
  # 실제로 무언가를 **하는** 호출만 활동으로 친다.
  @passive ~w(work_summary list_projects list_series list_presets list_channels
              status next flow_job flow_status channel_status settings_status
              list_languages dashboard cost_report render_prompt)

  @doc "도구 호출 하나를 남긴다. 실패해도 호출 자체를 막지 않는다."
  def record(name) when is_binary(name) do
    entry = %{
      "tool" => name,
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "active" => name not in @passive
    }

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_naive()
    recent = [entry | list()] |> Enum.take(@keep)

    Repo.insert_all(
      "app_state",
      [[key: @key, value: %{"recent" => recent}, inserted_at: now, updated_at: now]],
      on_conflict: [set: [value: %{"recent" => recent}, updated_at: now]],
      conflict_target: :key
    )

    :ok
  rescue
    _ -> :ok
  end

  def record(_), do: :ok

  @doc "최근 호출 목록. 새것부터."
  def list do
    case Repo.one(from a in "app_state", where: a.key == ^@key, select: a.value) do
      %{"recent" => recent} when is_list(recent) -> recent
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  지금 누가 일하고 있는가.

  `working?` 는 **뭔가를 하는 호출**이 최근 15분 안에 있었는지다.
  Flow 영상 단계는 한 번에 15분까지 조용할 수 있어서 그보다 짧게 잡으면
  일하는 중에 "멈췄다" 고 잘못 뜬다.
  """
  def summary do
    recent = list()
    last = List.first(recent)
    last_active = Enum.find(recent, & &1["active"])

    %{
      last: last && decorate(last),
      last_active: last_active && decorate(last_active),
      working?: within?(last_active, 15 * 60),
      recent: Enum.map(recent, &decorate/1)
    }
  end

  defp decorate(%{"at" => at} = e) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} ->
        Map.put(e, "ago_sec", DateTime.diff(DateTime.utc_now(), dt))

      _ ->
        Map.put(e, "ago_sec", nil)
    end
  end

  defp within?(nil, _), do: false

  defp within?(entry, seconds) do
    case decorate(entry)["ago_sec"] do
      n when is_integer(n) -> n <= seconds
      _ -> false
    end
  end
end
