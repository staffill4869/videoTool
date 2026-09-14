defmodule VideoTool.Repo.Migrations.FlowAutoByDefault do
  @moduledoc """
  생성 경로를 `flow_auto` 하나로 굳힌다.

  `ai` 는 "사람이 Flow 를 직접 조작한다" 는 뜻이었다. 무인 루프로 도는 지금은
  사람이 붙을 일이 없으므로, 그 값으로 만들어진 편은 아무도 밀어 주지 않고 서 있는다.
  고를 수 있게 두면 새 시리즈가 기본값(`ai`)으로 만들어져 조용히 멈춘다.
  """
  use Ecto.Migration

  def up do
    alter table(:series) do
      modify :pipeline, :string, default: "flow_auto"
    end

    alter table(:projects) do
      modify :pipeline, :string, default: "flow_auto"
    end

    execute "UPDATE series SET pipeline = 'flow_auto' WHERE pipeline <> 'flow_auto'"
    execute "UPDATE projects SET pipeline = 'flow_auto' WHERE pipeline <> 'flow_auto'"
  end

  def down do
    alter table(:series) do
      modify :pipeline, :string, default: "ai"
    end

    alter table(:projects) do
      modify :pipeline, :string, default: "ai"
    end
  end
end
