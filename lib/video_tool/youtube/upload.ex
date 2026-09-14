defmodule VideoTool.YouTube.Upload do
  @moduledoc """
  유튜브 업로드. `videos.insert` 는 재개 가능(resumable) 업로드를 쓴다.

  두 단계다.
    1. 세션 시작 — 메타데이터만 보내고 `Location` 헤더로 업로드 URL 을 받는다
    2. 파일 전송 — 그 URL 로 바이트를 올린다

  한 번에 보내지 않는 이유: 영상은 수십~수백 MB 라 중간에 끊기면 처음부터 다시 올려야 한다.

  할당량: `videos.insert` 1,600 units · `thumbnails.set` 50 · `captions.insert` 400.
  기본 10,000/일이면 하루 5~6편이다. 통계 조회(1 unit)와 달리 아껴 써야 한다.
  """

  alias VideoTool.Media
  alias VideoTool.Publishing.GoogleOAuth

  @insert_url "https://www.googleapis.com/upload/youtube/v3/videos"
  @thumbnail_url "https://www.googleapis.com/upload/youtube/v3/thumbnails/set"
  @captions_url "https://www.googleapis.com/upload/youtube/v3/captions"
  @chunk 8 * 1024 * 1024

  @doc """
  발행물 하나를 올린다.

  영상이 올라간 뒤 섬네일·자막이 실패해도 발행을 되돌리지 않는다 —
  되돌리려고 지웠다가 이미 올라간 영상을 잃는 게 더 나쁘다. 결과에 각각의 성패를 담아 돌려준다.
  """
  def publish(publication, project, channel, render) do
    with {:ok, token} <- GoogleOAuth.access_token(channel),
         :ok <- file_exists(render.file_path),
         {:ok, video_id} <- insert_video(token, publication, project, channel, render) do
      {:ok,
       %{
         video_id: video_id,
         url: "https://youtu.be/#{video_id}",
         thumbnail: maybe_thumbnail(token, video_id, render),
         captions: maybe_captions(token, video_id, publication, project)
       }}
    end
  end

  defp file_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, "완성본 파일이 없습니다: #{path}"}
  end

  # ── 세션 시작 → 파일 전송 ───────────────────────────────────────

  defp insert_video(token, publication, project, channel, render) do
    size = File.stat!(render.file_path).size

    metadata = %{
      "snippet" => %{
        "title" => title_for(publication, channel),
        "description" => description_for(publication, channel),
        "tags" => publication.hashtags,
        "categoryId" => channel.default_category,
        "defaultLanguage" => project.language,
        "defaultAudioLanguage" => project.language
      },
      "status" =>
        maybe_schedule(
          %{"privacyStatus" => publication.privacy, "selfDeclaredMadeForKids" => false},
          publication
        )
    }

    headers = [
      {"authorization", "Bearer " <> token},
      {"x-upload-content-length", Integer.to_string(size)},
      {"x-upload-content-type", "video/mp4"}
    ]

    case Req.post(@insert_url,
           params: [uploadType: "resumable", part: "snippet,status"],
           headers: headers,
           json: metadata,
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, headers: resp_headers}} ->
        case location(resp_headers) do
          nil -> {:error, "업로드 세션 URL 을 받지 못했습니다"}
          url -> send_bytes(url, render.file_path, size)
        end

      {:ok, %{status: status, body: body}} ->
        {:error, "업로드 세션 시작 실패 (#{status}): #{describe(body)}"}

      {:error, reason} ->
        {:error, "업로드 세션 호출 실패: #{inspect(reason)}"}
    end
  end

  # 예약 발행은 비공개 상태에서만 유효하다. 공개인데 publishAt 을 주면 구글이 거절한다.
  defp maybe_schedule(status, %{scheduled_at: nil}), do: status

  defp maybe_schedule(status, %{scheduled_at: at}) do
    status
    |> Map.put("publishAt", DateTime.to_iso8601(at))
    |> Map.put("privacyStatus", "private")
  end

  defp send_bytes(url, path, size) do
    headers = [{"content-type", "video/mp4"}, {"content-length", Integer.to_string(size)}]

    case Req.put(url,
           headers: headers,
           body: File.stream!(path, @chunk),
           receive_timeout: 1_800_000,
           retry: false
         ) do
      {:ok, %{status: status, body: %{"id" => id}}} when status in [200, 201] ->
        {:ok, id}

      {:ok, %{status: status, body: body}} ->
        {:error, "파일 전송 실패 (#{status}): #{describe(body)}"}

      {:error, reason} ->
        {:error, "파일 전송 호출 실패: #{inspect(reason)}"}
    end
  end

  defp location(headers) do
    case Enum.find(headers, fn {k, _} -> String.downcase(k) == "location" end) do
      {_, [value | _]} -> value
      {_, value} when is_binary(value) -> value
      _ -> nil
    end
  end

  # ── 섬네일 · 자막 ───────────────────────────────────────────────

  defp maybe_thumbnail(token, video_id, render) do
    case thumbnail_file(render) do
      nil ->
        %{ok: false, reason: "섬네일 없음"}

      path ->
        headers = [{"authorization", "Bearer " <> token}, {"content-type", image_type(path)}]

        case Req.post(@thumbnail_url,
               params: [videoId: video_id],
               headers: headers,
               body: File.read!(path),
               receive_timeout: 60_000
             ) do
          {:ok, %{status: 200}} -> %{ok: true}
          {:ok, %{status: status, body: body}} -> %{ok: false, reason: "#{status}: #{describe(body)}"}
          {:error, reason} -> %{ok: false, reason: inspect(reason)}
        end
    end
  end

  # 등록된 경로가 먼저다. 없으면 프로젝트 폴더에 떨어뜨려 둔 파일을 줍는다 —
  # 섬네일을 그려 놓고 save_thumbnail 을 안 불러서 "섬네일 없음" 으로 올라간 적이 있다.
  # 파일이 거기 있는데 이름을 안 알려줬다는 이유로 안 올리는 건 도움이 안 된다.
  defp thumbnail_file(render) do
    registered = if render.thumbnail_path != "", do: render.thumbnail_path

    [registered | Path.wildcard("projects/#{render.project_id}/{thumb,thumbnail}.{jpg,jpeg,png}")]
    |> Enum.find(&(is_binary(&1) and File.exists?(&1)))
  end

  defp image_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      _ -> "image/jpeg"
    end
  end

  defp maybe_captions(token, video_id, publication, project) do
    narration = Media.latest_narration(publication.project_id)
    subtitles = narration && Media.subtitles(narration.id)

    cond do
      is_nil(narration) -> %{ok: false, reason: "나레이션 없음"}
      subtitles == [] -> %{ok: false, reason: "자막 없음"}
      true -> upload_captions(token, video_id, subtitles, project)
    end
  end

  defp upload_captions(token, video_id, subtitles, project) do
    metadata = %{
      "snippet" => %{
        "videoId" => video_id,
        "language" => project.language,
        "name" => "",
        "isDraft" => false
      }
    }

    # captions.insert 는 메타데이터와 자막 파일을 함께 보내는 **multipart/related** 다.
    # Req 에 `{:multipart, [...]}` 튜플을 그냥 넘기면 "protocol Enumerable not implemented
    # for Tuple" 로 죽는다 (실측: 영상은 올라간 뒤 여기서 터졌다). 게다가 Req 의
    # form_multipart 는 multipart/form-data 라 규격이 다르다. 그래서 몸통을 직접 만든다.
    boundary = "vt" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))

    body =
      "--#{boundary}
" <>
        "Content-Type: application/json; charset=UTF-8

" <>
        Jason.encode!(metadata) <>
        "
--#{boundary}
" <>
        "Content-Type: application/octet-stream

" <>
        to_srt(subtitles) <>
        "
--#{boundary}--
"

    case Req.post(@captions_url,
           params: [part: "snippet", uploadType: "multipart"],
           headers: [
             {"authorization", "Bearer " <> token},
             {"content-type", "multipart/related; boundary=#{boundary}"}
           ],
           body: body,
           receive_timeout: 120_000
         ) do
      {:ok, %{status: status}} when status in [200, 201] -> %{ok: true}
      {:ok, %{status: status, body: body}} -> %{ok: false, reason: "#{status}: #{describe(body)}"}
      {:error, reason} -> %{ok: false, reason: inspect(reason)}
    end
  end

  @doc "자막을 SRT 로. 유튜브가 받는 형식이다."
  def to_srt(subtitles) do
    subtitles
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {s, i} ->
      "#{i}\n#{timestamp(s.start_sec)} --> #{timestamp(s.end_sec)}\n#{s.text}\n"
    end)
  end

  defp timestamp(seconds) do
    total = trunc(seconds)
    ms = round((seconds - total) * 1000)
    h = div(total, 3600)
    m = total |> rem(3600) |> div(60)
    s = rem(total, 60)

    :io_lib.format("~2..0B:~2..0B:~2..0B,~3..0B", [h, m, s, ms]) |> List.to_string()
  end

  # ── 제목·설명 ───────────────────────────────────────────────────

  defp title_for(publication, channel) do
    channel.title_pattern
    |> String.replace("{title}", publication.title)
    |> String.slice(0, 100)
  end

  defp description_for(publication, channel) do
    hashtags = Enum.map_join(publication.hashtags, " ", &("#" <> &1))

    channel.description_pattern
    |> String.replace("{description}", publication.description)
    |> String.replace("{hashtags}", hashtags)
    |> String.slice(0, 5000)
  end

  defp describe(%{"error" => %{"message" => message}}), do: message
  defp describe(body), do: body |> inspect() |> String.slice(0, 300)
end