import Ecto.Query
alias VideoTool.Repo
pid = String.to_integer(System.get_env("PRJ") || "153")
scenes = Repo.all(from s in VideoTool.Projects.Scene, where: s.project_id == ^pid, order_by: s.scene_no, select: {s.id, s.scene_no})
have = Repo.all(from a in VideoTool.Media.Asset, where: a.project_id == ^pid and a.kind == "clip" and a.status != "rejected", select: a.scene_id) |> MapSet.new()
miss = for {sid, no} <- scenes, not MapSet.member?(have, sid), do: no
IO.puts("MISS " <> Enum.join(miss, " "))
