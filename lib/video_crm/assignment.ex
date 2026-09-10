defmodule VideoCRM.Assignment do
  @moduledoc """
  헝가리안 알고리즘 (O(n³), e-maxx 형태의 잠재값 + 증대경로).

  왜 직접 짜는가: hex 에 쓸 만한 패키지가 없다.
  왜 탐욕법이 아닌가: 이 배정이 틀리면 영상 순서가 통째로 틀린다. 실제로 Flow 파일명이
  내용과 무관해서 사람이 15~18개를 눈으로 맞췄던 부분이라, 근사해로 때울 자리가 아니다.
  n 이 15~18 이라 O(n³) 은 순식간이다.
  """

  @inf 1.0e9

  @doc """
  비용 최소 배정. `rows` 는 n×m 행렬(리스트의 리스트), n ≤ m.
  반환값은 `%{행 => 열}` (0부터 센다).
  """
  def solve([]), do: %{}

  def solve(rows) when is_list(rows) do
    n = length(rows)
    m = rows |> hd() |> length()

    if m < n do
      raise ArgumentError, "열(#{m})이 행(#{n})보다 적으면 전단사 배정이 불가능합니다"
    end

    a = rows |> Enum.map(&List.to_tuple/1) |> List.to_tuple()

    state = %{
      u: Tuple.duplicate(0.0, n + 1),
      v: Tuple.duplicate(0.0, m + 1),
      p: Tuple.duplicate(0, m + 1),
      way: Tuple.duplicate(0, m + 1)
    }

    final = Enum.reduce(1..n, state, fn i, st -> augment(a, i, m, st) end)

    for j <- 1..m, elem(final.p, j) != 0, into: %{} do
      {elem(final.p, j) - 1, j - 1}
    end
  end

  @doc "점수 최대 배정. 유사도 행렬을 그대로 넣으면 된다."
  def solve_max(rows) do
    rows |> Enum.map(fn row -> Enum.map(row, &(-&1)) end) |> solve()
  end

  # ── 내부 (1부터 세는 인덱스) ────────────────────────────────────

  defp augment(a, i, m, st) do
    st = %{st | p: put_elem(st.p, 0, i)}
    minv = Tuple.duplicate(@inf, m + 1)
    used = Tuple.duplicate(false, m + 1)

    {st, j0} = phase(a, m, 0, st, minv, used)
    reconstruct(st, j0)
  end

  defp phase(a, m, j0, st, minv, used) do
    used = put_elem(used, j0, true)
    i0 = elem(st.p, j0)

    {delta, j1, minv, way} =
      Enum.reduce(1..m, {@inf, 0, minv, st.way}, fn j, {delta, j1, minv, way} ->
        if elem(used, j) do
          {delta, j1, minv, way}
        else
          cur = cost(a, i0, j) - elem(st.u, i0) - elem(st.v, j)

          {minv, way} =
            if cur < elem(minv, j),
              do: {put_elem(minv, j, cur), put_elem(way, j, j0)},
              else: {minv, way}

          if elem(minv, j) < delta,
            do: {elem(minv, j), j, minv, way},
            else: {delta, j1, minv, way}
        end
      end)

    {u, v, minv} =
      Enum.reduce(0..m, {st.u, st.v, minv}, fn j, {u, v, minv} ->
        if elem(used, j) do
          pj = elem(st.p, j)
          {put_elem(u, pj, elem(u, pj) + delta), put_elem(v, j, elem(v, j) - delta), minv}
        else
          {u, v, put_elem(minv, j, elem(minv, j) - delta)}
        end
      end)

    st = %{st | u: u, v: v, way: way}

    if elem(st.p, j1) == 0 do
      {st, j1}
    else
      phase(a, m, j1, st, minv, used)
    end
  end

  defp reconstruct(st, 0), do: st

  defp reconstruct(st, j0) do
    j1 = elem(st.way, j0)
    reconstruct(%{st | p: put_elem(st.p, j0, elem(st.p, j1))}, j1)
  end

  defp cost(a, i, j), do: a |> elem(i - 1) |> elem(j - 1) |> :erlang.float()
end