defmodule VideoToolWeb.RenderController do
  @moduledoc """
  완성본 재생. `<video>` 가 탐색(seek)하려면 Range 요청에 206 으로 답해야 한다 —
  200 으로 통째로만 주면 재생은 되는데 타임라인을 못 끈다.

  자산 미리보기와 마찬가지로 작업 폴더 밖의 파일은 내주지 않는다.
  id 만 바꿔 임의 경로를 읽는 걸 막기 위해서다.
  """
  use VideoToolWeb, :controller

  alias VideoTool.{Media, Projects, Repo}

  def play(conn, %{"id" => id} = params) do
    with {:ok, render} <- fetch(id),
         {:ok, path} <- pick_file(render, params["variant"]),
         :ok <- inside_work_root(path) do
      serve(conn, path)
    else
      {:error, reason} -> conn |> put_status(404) |> text(reason)
    end
  end

  defp fetch(id) do
    case Repo.get(Media.Render, id) do
      nil -> {:error, "완성본 #{id} 없음"}
      render -> {:ok, render}
    end
  end

  # variant=master 면 자막 없는 마스터를 준다. 자막이 가린 화면을 확인할 때 쓴다.
  defp pick_file(render, "master") do
    case get_in(render.settings, ["master_no_subs"]) do
      nil -> pick_file(render, nil)
      path -> exists(path)
    end
  end

  defp pick_file(render, _), do: exists(render.file_path)

  defp exists(path), do: if(File.exists?(path), do: {:ok, path}, else: {:error, "파일이 없습니다"})

  defp inside_work_root(path) do
    file = Path.expand(path)
    root = Path.expand(Projects.work_root())

    if String.starts_with?(file, root <> "/") or String.starts_with?(file, root <> "\\") do
      :ok
    else
      {:error, "작업 폴더 밖의 파일입니다"}
    end
  end

  defp serve(conn, path) do
    size = File.stat!(path).size

    conn =
      conn
      |> put_resp_header("content-type", content_type(path))
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("cache-control", "private, max-age=60")

    case range(conn, size) do
      nil ->
        send_file(conn, 200, path)

      {from, to} ->
        conn
        |> put_resp_header("content-range", "bytes #{from}-#{to}/#{size}")
        |> send_file(206, path, from, to - from + 1)
    end
  end

  # 여러 구간을 한 번에 요청하는 경우는 다루지 않는다. 브라우저는 한 구간만 쓴다.
  defp range(conn, size) do
    with [value] <- get_req_header(conn, "range"),
         %{"from" => from_s, "to" => to_s} <-
           Regex.named_captures(~r/^bytes=(?<from>\d*)-(?<to>\d*)$/, String.trim(value)) do
      clamp(from_s, to_s, size)
    else
      _ -> nil
    end
  end

  # "bytes=500-" 은 500부터 끝까지, "bytes=-500" 은 마지막 500바이트를 뜻한다.
  defp clamp("", "", _size), do: nil

  defp clamp("", to_s, size) do
    last = String.to_integer(to_s)
    from = max(size - last, 0)
    if from < size, do: {from, size - 1}, else: nil
  end

  defp clamp(from_s, to_s, size) do
    from = String.to_integer(from_s)
    to = if to_s == "", do: size - 1, else: min(String.to_integer(to_s), size - 1)
    if from <= to and from < size, do: {from, to}, else: nil
  end

  defp content_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".mp4" -> "video/mp4"
      ".webm" -> "video/webm"
      ".mov" -> "video/quicktime"
      ".wav" -> "audio/wav"
      ".mp3" -> "audio/mpeg"
      _ -> "application/octet-stream"
    end
  end
end
