defmodule VideoTool.FlowStub do
  @moduledoc """
  테스트용 Flow 스텁. 실제 브라우저를 띄우지 않는다 —
  테스트가 Chrome 이 떠 있는지에 좌우되면 깨졌는지 아닌지를 알 수 없게 된다.

  `:flow_stub_status` 를 바꿔 준비된 상태 / 로그인 안 된 상태 / 연결 실패를 흉내 낸다.
  """

  def auto?(%{pipeline: "flow_auto"}), do: true
  def auto?(_), do: false

  def status do
    Application.get_env(:video_tool, :flow_stub_status, {:error, "Chrome 에 붙지 못했습니다 (스텁)"})
  end

  # 스텁에서는 편집기를 열 수 없으니 상태를 그대로 돌려준다.
  def ensure_editor(_project), do: status()
  def fresh_editor(_project), do: status()
  def project_editor(_project), do: status()

  def run_stage_async(project, stage, _prompt, _expect) do
    send(self(), {:flow_started, project.id, stage})
    VideoTool.Jobs.record_generation(%{
      project_id: project.id,
      provider: "flow",
      model: stage,
      status: "running",
      requested_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end
end