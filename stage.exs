import Ecto.Query
alias VideoTool.Repo
pid = String.to_integer(System.get_env("PRJ") || "0")
scenes = Repo.aggregate(from(s in VideoTool.Projects.Scene, where: s.project_id == ^pid), :count)
out =
  for k <- ["clean", "info"] do
    n = Repo.aggregate(from(a in VideoTool.Media.Asset, where: a.project_id == ^pid and a.kind == ^k and a.status != "rejected"), :count)
    if n < scenes, do: "#{k}:need", else: nil
  end
IO.puts("STAGE " <> Enum.join(Enum.reject(out, &is_nil/1), " "))
