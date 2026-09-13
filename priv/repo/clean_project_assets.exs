# 화면비가 안 맞는 자산을 지우고 배정을 다시 잡는다.
#
# 상시 지시가 생기기 전에 만든 가로본이 세로본과 섞여 있으면, 장면마다 둘이 겹쳐 붙어
# 전부 low_confidence 가 된다. 그 위에 INFO 를 올리면 결과물을 못 쓴다.
#
#   mix run priv/repo/clean_project_assets.exs 13

alias VideoTool.{Media, Projects, Repo}
alias VideoTool.Media.Asset

[project_id_str | _] = System.argv()
project_id = String.to_integer(project_id_str)
{:ok, project} = Projects.get_project(project_id)

want = project.aspect || "16:9"
IO.puts("프로젝트 #{project_id} — 목표 화면비 #{want}")

# 실제 픽셀로 판단한다. 파일 이름이나 생성 시각으로 고르면 틀린다.
matches? = fn a ->
  cond do
    a.width == 0 or a.height == 0 -> nil
    want == "9:16" -> a.height > a.width
    want == "16:9" -> a.width > a.height
    true -> true
  end
end

for kind <- ~w(clean info clip) do
  assets = Media.list_assets(project_id, kind)

  {keep, drop} =
    Enum.split_with(assets, fn a -> matches?.(a) != false end)

  IO.puts("\n[#{kind}] 전체 #{length(assets)}  유지 #{length(keep)}  삭제 #{length(drop)}")

  Enum.each(drop, fn a ->
    IO.puts("  지움  ##{a.id}  #{a.width}x#{a.height}  #{Path.basename(a.file_path)}")
    # 파일은 남겨둔다 — 되돌릴 일이 생기면 다시 등록하면 된다.
    Repo.delete!(a)
  end)
end

# 남은 것으로 배정을 다시 잡는다. 겹쳐 붙어 있던 게 풀린다.
for kind <- ~w(clean info clip) do
  assets = Media.list_assets(project_id, kind)

  if assets != [] do
    placed = VideoTool.Mapping.assign(project, kind, assets)

    Enum.each(placed, fn {asset_id, {scene_id, conf}} ->
      case Media.get_asset(asset_id) do
        nil -> :ok
        a -> Media.update_asset(a, %{scene_id: scene_id, order_confidence: conf})
      end
    end)

    low = Enum.count(placed, fn {_, {_, c}} -> VideoTool.Mapping.low_confidence?(c) end)
    IO.puts("[#{kind}] 재배정 #{map_size(placed)}건 (신뢰도 낮음 #{low})")
  end
end

scenes = length(Projects.scenes(project_id))
counts = Media.mapped_counts(project_id)
IO.puts("\n장면 #{scenes}개 기준 배정 결과: #{inspect(counts)}")
