defmodule VideoTool.Ingest do
  @moduledoc """
  Downloads 에 떨어진 Flow zip 을 가져와 장면에 붙인다.

  이 단계가 없애는 왕복: zip 받기 → 채팅에 올리기 → 압축 풀기 → 순서 맞추기.
  특히 순서는 사람이 15~18개 영상의 마지막 프레임을 눈으로 보고 맞추던 부분이다.
  """

  require Logger

  alias VideoTool.{Ffmpeg, Jobs, Mapping, Media, Phash, Projects, Validation}

  @image_ext ~w(.png .jpg .jpeg .webp)
  @video_ext ~w(.mp4 .mov .webm .mkv)

  @doc """
  `path` 를 주지 않으면 Downloads 에서 가장 최근 zip 을 찾는다.
  """
  def run(project, path \\ nil) do
    with {:ok, zip} <- resolve_zip(path),
         {:ok, job} <- start_job(project, zip),
         {:ok, files} <- extract(project, zip) do
      {images, videos} = split_media(files)

      registered =
        register(project, images, image_kind(project)) ++ register(project, videos, "clip")

      mapped = map_all(project, registered)
      {stage, validation} = validate_current(project)

      Jobs.update_ingest_job(job, %{
        extracted_count: length(files),
        mapped_count: map_size(mapped),
        method: method_used(),
        status: "done",
        log: "이미지 #{length(images)} / 영상 #{length(videos)} / 매핑 #{map_size(mapped)}"
      })

      {:ok,
       %{
         ingest_job_id: job.id,
         zip: zip,
         extracted: length(files),
         images: length(images),
         videos: length(videos),
         mapped: map_size(mapped),
         method: method_used(),
         low_confidence: low_confidence(mapped, project),
         unmapped: unmapped(registered, mapped),
         validation_stage: stage,
         validation: validation
       }}
    end
  end

  @doc """
  Downloads 에 **아직 안 가져온** zip 이 있으면 가져온다.

  파일 감시 GenServer 를 띄우지 않는 이유: `next/1` 이 불릴 때만 확인하면 충분하고,
  상시 프로세스는 서버가 죽었다 살아날 때 놓친 파일을 다시 못 잡는다.
  """
  def auto(project) do
    with {:ok, zip} <- resolve_zip(nil),
         true <- newer_than_last_ingest?(project, zip) do
      run(project, zip)
    else
      _ -> :none
    end
  end

  defp newer_than_last_ingest?(project, zip) do
    case Jobs.latest_ingest_job(project.id) do
      nil ->
        true

      %{file_mtime: nil} ->
        true

      %{file_mtime: last} ->
        case mtime(zip) do
          nil -> false
          m -> DateTime.compare(DateTime.from_unix!(m), last) == :gt
        end
    end
  end

  # ── zip 찾기 ────────────────────────────────────────────────────

  defp resolve_zip(nil) do
    dir = downloads_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(Path.extname(&1) == ".zip"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.map(&{&1, mtime(&1)})
        |> Enum.reject(fn {_p, m} -> is_nil(m) end)
        |> Enum.max_by(fn {_p, m} -> m end, fn -> nil end)
        |> case do
          nil -> {:error, "#{dir} 에 zip 이 없습니다"}
          {path, _} -> {:ok, path}
        end

      {:error, reason} ->
        {:error, "Downloads 를 읽을 수 없습니다 (#{dir}): #{inspect(reason)}"}
    end
  end

  defp resolve_zip(path) do
    if File.exists?(path), do: {:ok, path}, else: {:error, "파일이 없습니다: #{path}"}
  end

  def downloads_dir do
    Application.get_env(:video_tool, :downloads_dir) ||
      Path.join(System.user_home!(), "Downloads")
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: m}} -> m
      _ -> nil
    end
  end

  # ── 압축 해제 ───────────────────────────────────────────────────

  defp extract(project, zip) do
    dest =
      Path.join([project.work_dir, "ingest", to_string(System.os_time(:second))])

    File.mkdir_p!(dest)

    case :zip.unzip(String.to_charlist(zip), [{:cwd, String.to_charlist(dest)}]) do
      {:ok, entries} ->
        {:ok, entries |> Enum.map(&List.to_string/1) |> Enum.filter(&File.regular?/1)}

      {:error, reason} ->
        {:error, "zip 해제 실패 (#{Path.basename(zip)}): #{inspect(reason)}"}
    end
  end

  defp split_media(files) do
    {Enum.filter(files, &(ext(&1) in @image_ext)), Enum.filter(files, &(ext(&1) in @video_ext))}
  end

  defp ext(file), do: file |> Path.extname() |> String.downcase()

  # CLEAN 이 아직 없으면 이 이미지들이 CLEAN 이다. 있으면 INFO 다.
  defp image_kind(project) do
    if Media.asset_counts(project.id)["clean"] == 0, do: "clean", else: "info"
  end

  # ── 등록 ────────────────────────────────────────────────────────

  defp register(_project, [], _kind), do: []

  defp register(project, files, kind) do
    Enum.flat_map(files, fn file ->
      probe = probe_or_default(file)

      attrs =
        %{
          project_id: project.id,
          kind: kind,
          source: "flow",
          file_path: file,
          source_filename: Path.basename(file),
          width: probe.width,
          height: probe.height,
          duration_sec: probe.duration_sec,
          fps: probe.fps,
          status: "pending"
        }
        |> Map.merge(hashes(file, kind))

      case Media.create_asset(attrs) do
        {:ok, asset} ->
          [asset]

        {:error, changeset} ->
          Logger.error("자산 등록 실패 #{file}: #{inspect(changeset.errors)}")
          []
      end
    end)
  end

  defp probe_or_default(file) do
    case Ffmpeg.probe(file) do
      {:ok, p} -> p
      {:error, _} -> %{width: 0, height: 0, duration_sec: nil, fps: nil}
    end
  end

  # 클립만 해시가 두 개 필요하다.
  defp hashes(file, "clip") do
    %{phash: hash_or_blank(file, :first), phash_last: hash_or_blank(file, :last)}
  end

  defp hashes(file, _kind), do: %{phash: hash_or_blank(file, :first)}

  defp hash_or_blank(file, at) do
    case Phash.of_file(file, at) do
      {:ok, hash} ->
        hash

      {:error, reason} ->
        Logger.warning("해시 실패 #{Path.basename(file)} (#{at}): #{reason}")
        ""
    end
  end

  # ── 매핑 ────────────────────────────────────────────────────────

  defp map_all(project, registered) do
    registered
    |> Enum.group_by(& &1.kind)
    # CLEAN 을 먼저 붙여야 INFO·클립이 그걸 기준으로 삼을 수 있다.
    |> Enum.sort_by(fn {kind, _} -> Enum.find_index(["clean", "info", "clip"], &(&1 == kind)) end)
    |> Enum.reduce(%{}, fn {kind, assets}, acc ->
      # 각 kind 를 붙이기 전에 project 를 다시 읽는다 — 앞 단계 결과를 기준으로 써야 한다.
      {:ok, fresh} = Projects.get_project(project.id)
      assignment = Mapping.assign(fresh, kind, assets)

      Enum.each(assignment, fn {asset_id, {scene_id, confidence}} ->
        asset = Enum.find(assets, &(&1.id == asset_id))

        Media.update_asset(asset, %{
          scene_id: scene_id,
          order_confidence: confidence,
          status: "mapped"
        })
      end)

      Map.merge(acc, assignment)
    end)
  end

  defp low_confidence(mapped, project) do
    scenes = Map.new(Projects.scenes(project.id), &{&1.id, &1.scene_no})

    mapped
    |> Enum.filter(fn {_asset_id, {_scene_id, c}} -> Mapping.low_confidence?(c) end)
    |> Enum.map(fn {_asset_id, {scene_id, c}} ->
      %{scene_no: Map.get(scenes, scene_id), confidence: c}
    end)
    |> Enum.sort_by(& &1.confidence)
  end

  defp unmapped(registered, mapped) do
    registered
    |> Enum.reject(&Map.has_key?(mapped, &1.id))
    |> Enum.map(& &1.source_filename)
  end

  defp method_used do
    if VideoTool.Ocr.available?(), do: "ocr", else: "phash"
  end

  # ── 검증 ────────────────────────────────────────────────────────

  defp validate_current(project) do
    {:ok, fresh} = Projects.get_project(project.id)
    counts = Media.asset_counts(fresh.id)

    stage =
      cond do
        counts["clip"] > 0 -> "clips"
        counts["info"] > 0 -> "info"
        true -> "clean"
      end

    {:ok, result} = Validation.run(fresh, stage)
    {stage, result}
  end

  defp start_job(project, zip) do
    Jobs.create_ingest_job(%{
      project_id: project.id,
      watched_path: downloads_dir(),
      detected_file: Path.basename(zip),
      file_mtime: zip |> mtime() |> to_datetime(),
      status: "running"
    })
  end

  defp to_datetime(nil), do: nil
  defp to_datetime(posix), do: DateTime.from_unix!(posix) |> DateTime.truncate(:second)
end