# 단계별로 **아직 자산이 없는 장면 번호**를 찍는다.
#
# 예전에는 "자산 수 < 장면 수" 로 단계 전체를 다시 돌렸다. 훅 장면을 끼워 넣어
# 장면이 8→9 가 된 날, 멀쩡한 그림 8장을 통째로 다시 뽑게 생겼다 (2026-10-02).
# 빠진 장면만 찍어 주면 몇 번을 돌려도 같은 결과가 된다.
import Ecto.Query
alias VideoTool.Repo

pid = String.to_integer(System.get_env("PRJ") || "0")

scenes =
  Repo.all(
    from s in VideoTool.Projects.Scene,
      where: s.project_id == ^pid,
      order_by: s.scene_no,
      select: {s.id, s.scene_no}
  )

for kind <- ["clean", "info"] do
  have =
    Repo.all(
      from a in VideoTool.Media.Asset,
        where: a.project_id == ^pid and a.kind == ^kind and a.status != "rejected",
        select: a.scene_id
    )
    |> MapSet.new()

  miss = for {sid, no} <- scenes, not MapSet.member?(have, sid), do: no
  IO.puts("NEED #{kind} " <> Enum.join(miss, " "))
end
