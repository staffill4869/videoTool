defmodule VideoTool.AssemblyTest do
  use ExUnit.Case, async: true

  alias VideoTool.Assembly

  # 겹쳐 잇는 만큼 앞 조각을 길게 뽑아 두었으므로, 이어 붙인 총 길이는
  # "목표 길이의 합" 그대로여야 한다. 여기가 틀리면 나레이션이 밀린다.
  test "디졸브로 이어도 전체 길이는 목표 합과 같다" do
    targets = [7.92, 7.27, 6.94]
    overlaps = [0.3, 0.08, 0.0]
    durs = Enum.zip_with(targets, overlaps, &(&1 + &2))

    plan = Assembly.seam_plan(durs, overlaps)
    total = Enum.reduce(plan, Enum.at(durs, 0), fn {i, ov, _o}, acc -> acc + Enum.at(durs, i) - ov end)

    assert_in_delta total, Enum.sum(targets), 0.001
    assert [{1, 0.3, offset1}, {2, 0.08, _}] = plan
    assert_in_delta offset1, 7.92, 0.001
  end
end
