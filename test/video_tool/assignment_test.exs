defmodule VideoTool.AssignmentTest do
  @moduledoc "헝가리안이 진짜 전역 최적을 내는지. 틀리면 영상 순서가 통째로 틀린다."
  use ExUnit.Case, async: true

  alias VideoTool.Assignment

  test "탐욕법이 틀리는 고전 사례에서 전역 최적을 낸다" do
    # 탐욕법은 가장 작은 (0,0)=1 을 먼저 집고 (1,1)=100 에 갇혀 총합 101 이 된다.
    # 최적은 2+2=4.
    cost = [
      [1, 2],
      [2, 100]
    ]

    assert Assignment.solve(cost) == %{0 => 1, 1 => 0}
    assert total(cost, Assignment.solve(cost)) == 4
  end

  test "대각선이 최적이면 대각선을 고른다" do
    cost = [
      [0, 9, 9],
      [9, 0, 9],
      [9, 9, 0]
    ]

    assert Assignment.solve(cost) == %{0 => 0, 1 => 1, 2 => 2}
  end

  test "열이 더 많아도 각 행이 서로 다른 열을 받는다" do
    cost = [
      [4, 1, 9, 9],
      [9, 2, 3, 9]
    ]

    result = Assignment.solve(cost)

    assert map_size(result) == 2
    assert result |> Map.values() |> Enum.uniq() |> length() == 2
    assert total(cost, result) == 4
  end

  test "solve_max 는 유사도를 최대로 만든다" do
    similarity = [
      [0.9, 0.1],
      [0.8, 0.2]
    ]

    # 0.9+0.2=1.1 보다 0.1+0.8=0.9 가 작으므로 대각선이 답
    assert Assignment.solve_max(similarity) == %{0 => 0, 1 => 1}
  end

  test "무작위 행렬에서 완전탐색과 같은 총비용을 낸다" do
    :rand.seed(:exsss, {7, 7, 7})
    n = 6
    cost = for _ <- 1..n, do: for(_ <- 1..n, do: :rand.uniform(50))

    best =
      0..(n - 1)
      |> Enum.to_list()
      |> permutations()
      |> Enum.map(fn perm ->
        perm |> Enum.with_index() |> Enum.map(fn {col, row} -> at(cost, row, col) end) |> Enum.sum()
      end)
      |> Enum.min()

    assert total(cost, Assignment.solve(cost)) == best
  end

  test "빈 입력" do
    assert Assignment.solve([]) == %{}
  end

  test "열이 행보다 적으면 거절한다" do
    assert_raise ArgumentError, fn -> Assignment.solve([[1, 2], [3, 4], [5, 6]]) end
  end

  defp total(cost, assignment),
    do: Enum.reduce(assignment, 0, fn {row, col}, acc -> acc + at(cost, row, col) end)

  defp at(cost, row, col), do: cost |> Enum.at(row) |> Enum.at(col)

  defp permutations([]), do: [[]]

  defp permutations(list),
    do: for(head <- list, tail <- permutations(list -- [head]), do: [head | tail])
end