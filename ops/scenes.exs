# 이 프로젝트의 장면 번호를 모두 출력한다. 워커가 묶음을 **장면 수에 맞춰** 만들기 위함이다.
pid = String.to_integer(System.get_env("PRJ") || "0")
IO.puts("SCENES " <> Enum.map_join(VideoTool.Projects.scenes(pid), " ", & &1.scene_no))
