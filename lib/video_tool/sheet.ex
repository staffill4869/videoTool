defmodule VideoTool.Sheet do
  @moduledoc """
  콘택트 시트 — 한 단계의 결과물을 장면 순서대로 한 장에 늘어놓는다.

  **이게 무인 제작의 마지막 구멍을 막는다.** dHash 배정은 "클립이 자기 이미지와 맞는가"만
  보지 그 이미지가 몇 번 장면인지는 모른다. 그래서 배정 신뢰도가 0.99 여도 장면 순서는
  통째로 뒤섞여 있을 수 있다 (실측: 오늘 만든 여섯 편 전부 손으로 고쳐야 했다).

  고치려면 눈으로 봐야 하는데, 그건 사람만 할 수 있는 일이 아니다. 에이전트도 눈이 있다.
  이 도구가 한 장짜리 시트를 만들어 주면 에이전트가 보고 `remap_scenes` 를 부르면 된다.

  클립은 **마지막 프레임**을 쓴다. 영상은 CLEAN→INFO 보간이라 끝 프레임이 그 장면의
  결론(라벨이 다 얹힌 그림)이고, 그게 장면을 알아보는 가장 확실한 단서다.
  """

  require Logger

  alias VideoTool.{Media, Projects}

  @cols 4
  @thumb_w 220
  @thumb_h 390

  @doc """
  `kind` (clean · info · clip) 결과를 장면 순서대로 한 장에 붙인다.

  돌려주는 것: 시트 파일 경로, 칸마다 어느 장면인지, 그 장면 대사.
  칸 순서가 곧 "지금 배정" 이므로, 에이전트는 시트를 보고 대사와 안 맞는 칸을 찾아
  `remap_scenes(order: [...])` 로 고치면 된다.
  """
  def build(project, kind) when kind in ~w(clean info clip) do
    dir = Path.join([work_dir(project), "work"])
    File.mkdir_p!(dir)

    scenes = Projects.scenes(project.id)
    texts = segment_texts(project)

    by_scene =
      Media.list_assets(project.id, kind)
      |> Enum.filter(&(&1.scene_id && File.exists?(&1.file_path)))
      |> Enum.group_by(& &1.scene_id)
      |> Map.new(fn {sid, list} -> {sid, Enum.max_by(list, & &1.order_confidence)} end)

    cells =
      scenes
      |> Enum.filter(&Map.has_key?(by_scene, &1.id))
      |> Enum.map(&%{scene_no: &1.scene_no, asset: by_scene[&1.id], text: texts[&1.id] || ""})

    cond do
      cells == [] ->
        {:error, "#{kind} 결과가 아직 없습니다."}

      true ->
        # 빠진 장면이 있으면 ffmpeg 의 연속 번호 입력이 거기서 끊긴다.
        # 그래서 칸 번호를 1부터 다시 매겨 복사한다.
        Path.wildcard(Path.join(dir, "sheet_cell_*.jpg")) |> Enum.each(&File.rm/1)

        cells
        |> Enum.with_index(1)
        |> Enum.each(fn {cell, i} ->
          out = Path.join(dir, "sheet_cell_#{pad(i)}.jpg")
          grab(cell.asset, kind, out)
        end)

        sheet = Path.join(dir, "sheet_#{kind}.jpg")
        rows = ceil(length(cells) / @cols)

        args = [
          "-v", "error", "-y",
          "-start_number", "1",
          "-i", Path.join(dir, "sheet_cell_%02d.jpg"),
          "-vf", "tile=#{@cols}x#{rows}:padding=6:color=white",
          "-frames:v", "1",
          sheet
        ]

        case VideoTool.Ffmpeg.exec(args) do
          {:ok, _} ->
            {:ok,
             %{
               file_path: sheet,
               kind: kind,
               columns: @cols,
               cells:
                 Enum.map(cells, fn c ->
                   %{scene_no: c.scene_no, text: c.text}
                 end),
               note:
                 "칸은 왼쪽→오른쪽, 위→아래 순서로 #{@cols}개씩입니다. " <>
                   "칸 N 의 그림이 장면 N 대사와 맞는지 보세요. 어긋나면 " <>
                   "remap_scenes(kind: \"#{kind}\", order: [...]) 로 고칩니다 — " <>
                   "order 는 '1번 장면에 지금 몇 번 칸 그림을 쓸지' 의 나열입니다."
             }}

          {:error, reason} ->
            {:error, "시트를 못 만들었습니다: #{reason}"}
        end
    end
  end

  def build(_project, kind), do: {:error, "알 수 없는 단계입니다: #{kind}"}

  # 클립은 끝 프레임. 이미지는 그냥 그 장면.
  defp grab(asset, "clip", out) do
    VideoTool.Ffmpeg.exec([
      "-v", "error", "-y", "-sseof", "-1", "-i", asset.file_path,
      "-frames:v", "1", "-vf", "scale=#{@thumb_w}:#{@thumb_h}", out
    ])
  end

  defp grab(asset, _kind, out) do
    VideoTool.Ffmpeg.exec([
      "-v", "error", "-y", "-i", asset.file_path,
      "-frames:v", "1", "-vf", "scale=#{@thumb_w}:#{@thumb_h}", out
    ])
  end

  defp segment_texts(project) do
    case Projects.active_script(project.id) do
      nil ->
        %{}

      script ->
        script.id
        |> Projects.segments_for()
        |> Map.new(&{&1.scene_id, &1.text})
    end
  end

  defp pad(i), do: String.pad_leading("#{i}", 2, "0")

  defp work_dir(project),
    do: project.work_dir || Path.join([File.cwd!(), "projects", "#{project.id}"])
end
