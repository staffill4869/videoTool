defmodule VideoTool.IngestTest do
  @moduledoc """
  ingest 를 실제 파일로 끝까지 돌린다. ffmpeg 로 그림을 만들고 zip 으로 묶어서 넣는다.

  핵심 검사는 하나다: **파일명이 내용과 어긋나 있어도 올바른 장면에 붙는가.**
  실제로 `Battleships_facing_across_sea.mp4` 의 내용이 쿠릴 열도였고, 사람이 15~18개를
  눈으로 맞춰야 했다. 그래서 INFO·클립 fixture 는 이름 순서를 일부러 뒤집어 만든다.
  """
  use VideoTool.DataCase, async: false

  alias VideoTool.{Ffmpeg, Ingest, Media, Projects}

  @moduletag :ffmpeg

  setup_all do
    unless Ffmpeg.available?(), do: raise("ffmpeg 가 필요합니다")
    :ok
  end

  setup do
    Code.eval_file("priv/repo/seeds.exs")

    tmp = Path.join(System.tmp_dir!(), "vcrm_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    downloads = Path.join(tmp, "downloads")
    File.mkdir_p!(downloads)

    prev = Application.get_env(:video_tool, :downloads_dir)
    Application.put_env(:video_tool, :downloads_dir, downloads)

    {:ok, project} =
      Projects.create_project(%{
        "title" => "매핑 테스트",
        "target_sec" => 30,
        "style_slug" => "iso-lowpoly",
        "domain_slug" => "history-military",
        "voice_slug" => "mark",
        "output_folder" => tmp
      })

    {:ok, project} = Projects.get_project(project.id)
    {:ok, _script, _} = Projects.save_script(project, "본문", nil, "draft")

    {:ok, _} =
      Projects.save_scenes(
        project,
        Enum.map(1..3, fn n ->
          %{
            "scene_no" => n,
            "target_sec" => 8.0,
            "shot_prompt" => "SHOT S0#{n}",
            "info_instruction" => "라벨 #{n}",
            "expected_labels" => ["#{n}번"]
          }
        end)
      )

    on_exit(fn ->
      Application.put_env(:video_tool, :downloads_dir, prev)
      File.rm_rf(tmp)
      File.rm_rf(project.work_dir)
    end)

    {:ok, project: project, tmp: tmp, downloads: downloads}
  end

  test "fixture 가 서로 구분되는지 먼저 확인한다 — 이게 없으면 매핑 테스트가 우연히 통과한다", ctx do
    make_clean_zip(ctx)
    {:ok, _} = Ingest.run(ctx.project, nil)

    hashes = ctx.project.id |> Media.list_assets("clean") |> Enum.map(& &1.phash)

    assert length(Enum.uniq(hashes)) == 3,
           "세 장의 해시가 같다(#{inspect(hashes)}). 그림이 구분되지 않으면 매핑 배정은 " <>
             "동점이 되고, 순서대로 떨어진 결과가 정답처럼 보인다."
  end

  test "INFO 는 제 CLEAN 에 가장 가깝다 (2등과 뚜렷이 벌어진다)", ctx do
    make_clean_zip(ctx)
    {:ok, _} = Ingest.run(ctx.project, nil)
    make_info_zip(ctx)
    {:ok, _} = Ingest.run(ctx.project, nil)

    cleans = ctx.project.id |> Media.list_assets("clean") |> Enum.filter(& &1.scene_id)
    infos = ctx.project.id |> Media.list_assets("info") |> Enum.filter(& &1.scene_id)

    for info <- infos do
      own = Enum.find(cleans, &(&1.scene_id == info.scene_id))
      others = Enum.reject(cleans, &(&1.scene_id == info.scene_id))

      mine = VideoTool.Phash.similarity(own.phash, info.phash)
      best_other = others |> Enum.map(&VideoTool.Phash.similarity(&1.phash, info.phash)) |> Enum.max()

      assert mine > best_other + 0.02,
             "#{info.source_filename}: 제 짝 #{mine} vs 남 #{best_other} — 구분이 안 된다"
    end
  end

  test "CLEAN 을 가져와 3개 장면에 붙인다", ctx do
    make_clean_zip(ctx)

    {:ok, summary} = Ingest.run(ctx.project, nil)

    assert summary.extracted == 3
    assert summary.images == 3
    assert summary.mapped == 3
    assert summary.unmapped == []

    assets = Media.list_assets(ctx.project.id, "clean")
    assert length(assets) == 3
    assert Enum.all?(assets, &(&1.scene_id != nil))
    assert Enum.all?(assets, &(&1.phash != ""))
    # 320x180 = 16:9
    assert Enum.all?(assets, &(&1.width == 320 and &1.height == 180))
  end

  test "INFO 는 파일명이 뒤집혀 있어도 그림 내용으로 제 장면을 찾는다", ctx do
    make_clean_zip(ctx)
    {:ok, _} = Ingest.run(ctx.project, nil)
    clean_by_scene = scene_no_map(ctx.project, "clean")

    # z_01 이 1번 장면 그림, a_03 이 3번 장면 그림 — 이름 순서와 내용이 반대다
    make_info_zip(ctx)
    {:ok, summary} = Ingest.run(ctx.project, nil)

    assert summary.mapped == 3
    info_by_scene = scene_no_map(ctx.project, "info")

    for n <- 1..3 do
      assert Map.has_key?(info_by_scene, n), "#{n}번 장면에 INFO 가 안 붙었습니다"
    end

    # 이름 순서대로 붙었다면 z_01 이 3번에 갔을 것이다
    assert info_by_scene[1] |> Path.basename() =~ "z_01"
    assert info_by_scene[3] |> Path.basename() =~ "a_03"

    assert map_size(clean_by_scene) == 3
  end

  test "클립은 첫 프레임=CLEAN / 끝 프레임=INFO 체인으로 붙는다", ctx do
    make_clean_zip(ctx)
    {:ok, _} = Ingest.run(ctx.project, nil)
    make_info_zip(ctx)
    {:ok, _} = Ingest.run(ctx.project, nil)

    make_clip_zip(ctx)
    {:ok, summary} = Ingest.run(ctx.project, nil)

    assert summary.videos == 3
    assert summary.mapped == 3

    clips = Media.list_assets(ctx.project.id, "clip")
    assert Enum.all?(clips, &(&1.phash != "" and &1.phash_last != ""))
    assert Enum.all?(clips, &(&1.duration_sec > 7.5 and &1.duration_sec < 8.5))

    by_scene = scene_no_map(ctx.project, "clip")
    assert by_scene[1] |> Path.basename() =~ "clip_1"
    assert by_scene[3] |> Path.basename() =~ "clip_3"
  end

  test "OCR 이 없으면 허용 수치 검증을 통과로 위장하지 않는다", ctx do
    make_clean_zip(ctx)
    {:ok, _} = Ingest.run(ctx.project, nil)
    make_info_zip(ctx)
    {:ok, summary} = Ingest.run(ctx.project, nil)

    checks = summary.validation.checks

    if VideoTool.Ocr.available?() do
      assert is_boolean(checks["allowed_facts"])
    else
      assert checks["allowed_facts"] == "skipped_no_ocr"
      assert Enum.any?(summary.validation.warnings, &(&1 =~ "tesseract"))
    end
  end

  test "같은 zip 을 두 번 가져오지 않는다", ctx do
    make_clean_zip(ctx)

    assert {:ok, _} = Ingest.auto(ctx.project)
    assert Ingest.auto(ctx.project) == :none
    assert length(Media.list_assets(ctx.project.id, "clean")) == 3
  end

  # ── fixture ─────────────────────────────────────────────────────

  # 서로 확실히 구분되는 3장. 흰 막대의 가로 위치가 장면마다 다르다.
  #
  # 처음에는 `testsrc2` 의 다른 시각을 썼는데, 9x8 로 줄이면 세 장의 dHash 가 전부 같아서
  # 헝가리안이 동점을 순서대로 배정했고 테스트가 우연히 통과했다. fixture 가 구분되지 않으면
  # 매핑 테스트는 아무것도 검증하지 못한다 — 그래서 아래 "fixture 가 구분되는가" 검사가 있다.
  defp clean_png(dir, n) do
    path = Path.join(dir, "clean_#{n}.png")
    x = 20 + (n - 1) * 110

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=320x180",
         "-vf", "drawbox=x=#{x}:y=20:w=60:h=130:color=white:t=fill",
         "-frames:v", "1", path],
        stderr_to_stdout: true
      )

    path
  end

  # CLEAN 위에 작은 라벨 상자를 얹은 것 = INFO. 밑그림이 같으니 phash 가 제 짝에 가깝다.
  # 라벨은 흰 막대와 겹치지 않는 아래쪽 구석에 둔다.
  defp info_png(dir, clean_path, name) do
    path = Path.join(dir, name)

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ["-v", "error", "-y", "-i", clean_path,
         "-vf", "drawbox=x=4:y=162:w=44:h=14:color=red:t=fill",
         "-frames:v", "1", path],
        stderr_to_stdout: true
      )

    path
  end

  # 앞 4초 CLEAN, 뒤 4초 INFO = 8초 클립.
  defp clip_mp4(dir, clean_path, info_path, name) do
    path = Path.join(dir, name)

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ["-v", "error", "-y",
         "-loop", "1", "-t", "4", "-i", clean_path,
         "-loop", "1", "-t", "4", "-i", info_path,
         "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]",
         "-map", "[v]", "-r", "10", "-pix_fmt", "yuv420p", path],
        stderr_to_stdout: true
      )

    path
  end

  defp make_clean_zip(ctx) do
    work = Path.join(ctx.tmp, "gen_clean")
    File.mkdir_p!(work)
    files = Enum.map(1..3, &clean_png(work, &1))
    zip(ctx.downloads, "flow_clean.zip", files)
  end

  defp make_info_zip(ctx) do
    work = Path.join(ctx.tmp, "gen_info")
    File.mkdir_p!(work)
    src = Path.join(ctx.tmp, "gen_clean")

    # 이름 순서를 내용과 반대로 붙인다
    names = %{1 => "z_01_info.png", 2 => "m_02_info.png", 3 => "a_03_info.png"}
    files = Enum.map(1..3, &info_png(work, Path.join(src, "clean_#{&1}.png"), names[&1]))
    zip(ctx.downloads, "flow_info.zip", files)
  end

  defp make_clip_zip(ctx) do
    work = Path.join(ctx.tmp, "gen_clip")
    File.mkdir_p!(work)
    clean_dir = Path.join(ctx.tmp, "gen_clean")
    info_dir = Path.join(ctx.tmp, "gen_info")
    names = %{1 => "z_01_info.png", 2 => "m_02_info.png", 3 => "a_03_info.png"}

    files =
      Enum.map(1..3, fn n ->
        clip_mp4(
          work,
          Path.join(clean_dir, "clean_#{n}.png"),
          Path.join(info_dir, names[n]),
          "clip_#{n}.mp4"
        )
      end)

    zip(ctx.downloads, "flow_clips.zip", files)
  end

  defp zip(dest_dir, name, files) do
    path = Path.join(dest_dir, name)

    entries =
      Enum.map(files, fn f -> {String.to_charlist(Path.basename(f)), File.read!(f)} end)

    {:ok, _} = :zip.create(String.to_charlist(path), entries)
    # mtime 비교가 초 단위라 직전 zip 과 겹치지 않게 한 칸 민다
    File.touch!(path, System.os_time(:second) + 1)
    path
  end

  defp scene_no_map(project, kind) do
    project.id
    |> Media.list_assets(kind)
    |> Enum.filter(& &1.scene_id)
    |> Map.new(fn a -> {a.scene.scene_no, a.file_path} end)
  end
end