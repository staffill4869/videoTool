defmodule VideoToolWeb.AssetController do
  @moduledoc """
  자산 미리보기. 파일이 프로젝트 작업 폴더 밖에 있으면 내주지 않는다 —
  id 만 바꿔 임의 경로를 읽는 걸 막기 위해서다.

  영상은 프레임을 뽑아 캐시한다. 프레임을 매번 뽑으면 목록 한 장에 ffmpeg 가 수십 번 뜬다.
  """
  use VideoToolWeb, :controller

  alias VideoTool.{Ffmpeg, Media, Projects, Repo}

  def preview(conn, %{"id" => id} = params) do
    with {:ok, asset} <- fetch_asset(id),
         {:ok, project} <- Projects.get_project(asset.project_id),
         :ok <- inside_work_dir(asset, project),
         {:ok, path} <- previewable(asset, params["at"]) do
      conn
      |> put_resp_header("cache-control", "private, max-age=60")
      |> send_file(200, path)
    else
      {:error, reason} -> conn |> put_status(404) |> text(reason)
    end
  end

  defp fetch_asset(id) do
    case Repo.get(Media.Asset, id) do
      nil -> {:error, "자산 #{id} 없음"}
      asset -> {:ok, asset}
    end
  end

  # 언어판은 원본 프로젝트의 CLEAN 이미지를 그대로 가리킨다 (글자가 없으니 재사용한다).
  # 그래서 "이 프로젝트 폴더 안" 이 아니라 "작업 루트 안" 을 경계로 삼는다.
  defp inside_work_dir(asset, _project) do
    file = Path.expand(asset.file_path)
    root = Path.expand(Projects.work_root())

    if String.starts_with?(file, root <> "/") or String.starts_with?(file, root <> "\\") do
      :ok
    else
      {:error, "작업 폴더 밖의 파일입니다"}
    end
  end

  defp previewable(asset, at) do
    cond do
      not File.exists?(asset.file_path) -> {:error, "파일이 없습니다"}
      asset.kind in ["clean", "info"] -> {:ok, asset.file_path}
      true -> video_frame(asset, at)
    end
  end

  defp video_frame(asset, at) do
    position = if at == "first", do: :first, else: :last
    dir = Path.join(Path.dirname(asset.file_path), ".thumbs")
    cache = Path.join(dir, "#{asset.id}_#{position}.png")

    if File.exists?(cache) do
      {:ok, cache}
    else
      File.mkdir_p!(dir)
      Ffmpeg.extract_frame(asset.file_path, cache, position)
    end
  end
end