# Flow 에서 받아온 클립을 장면에 연결한다.
#
# 지금은 매핑을 사람이 확인해서 넘긴다. Flow 그리드의 DOM 순서는 장면 순서가 아니다 —
# 실제로 이번에도 1→3, 2→1, 3→5, 4→4, 5→2 로 뒤섞여 있었다.
# 나중에는 클립 마지막 프레임과 INFO 이미지를 dHash 로 맞춰 자동화해야 한다.
#
#   mix run priv/repo/register_clips.exs 9 "clip_01.mp4:3,clip_02.mp4:1,..."

alias VideoTool.{Media, Projects, Ffmpeg}

[project_id_str, mapping_str] = System.argv()
project_id = String.to_integer(project_id_str)
{:ok, project} = Projects.get_project(project_id)

scenes = Projects.scenes(project_id) |> Map.new(&{&1.scene_no, &1.id})
dir = Path.join(project.work_dir, "clips")

mapping_str
|> String.split(",", trim: true)
|> Enum.each(fn pair ->
  [file, scene_no_str] = String.split(pair, ":")
  scene_no = String.to_integer(scene_no_str)
  path = Path.join(dir, file)

  scene_id = Map.fetch!(scenes, scene_no)
  {:ok, probe} = Ffmpeg.probe(path)

  attrs = %{
    project_id: project_id,
    scene_id: scene_id,
    kind: "clip",
    source: "flow",
    file_path: path,
    source_filename: file,
    width: probe.width,
    height: probe.height,
    duration_sec: probe.duration_sec,
    fps: probe.fps,
    order_confidence: 1.0,
    status: "approved"
  }

  case Media.create_asset(attrs) do
    {:ok, a} ->
      IO.puts("  #{file} → 장면 #{scene_no} (asset #{a.id}, #{probe.duration_sec}s #{probe.width}x#{probe.height})")

    {:error, cs} ->
      IO.puts("  #{file} 실패: #{inspect(cs.errors)}")
  end
end)

counts = Media.asset_counts(project_id)
IO.puts("\n등록 결과: #{inspect(counts)}")
