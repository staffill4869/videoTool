defmodule VideoTool.YouTube do
  @moduledoc """
  YouTube Data API v3.

  **필요한 자격이 용도마다 다르다.**

    * 조회수·좋아요·댓글 수 읽기 → **API 키 하나면 된다** (공개 영상 한정).
      `videos.list?part=statistics` 는 OAuth 를 요구하지 않는다.
    * 업로드·자막·섬네일 → OAuth 클라이언트(데스크톱 앱) + 사용자 동의가 필요하다.

  그래서 업로드 준비가 끝나기 전에 성과 수집부터 돌릴 수 있다. 굳이 함께 묶지 않는다.

  할당량: 기본 10,000 units/일. `videos.list` 는 호출당 1 unit 이고 id 를 50개까지
  한 번에 넣을 수 있어서, 하루에 수백 번 재도 남는다. 업로드가 1,600 units 로 비싸다.
  """


  @endpoint "https://www.googleapis.com/youtube/v3/videos"
  @batch 50

  @doc "API 키가 설정돼 있는가. 없으면 수집은 그냥 건너뛴다."
  def configured?, do: api_key() not in [nil, ""]

  # 화면에서 넣은 값(자격증명 저장소)이 .env 를 이긴다.
  def api_key, do: VideoTool.Settings.get(:google_api_key)

  @doc """
  영상 id 목록의 통계를 읽는다. `%{video_id => %{views:, likes:, comments:}}`.

  비공개·삭제된 영상은 응답에 아예 빠진다 — 그건 오류가 아니라 정보다.
  호출자가 "못 읽은 것" 으로 구분할 수 있게 결과에서 빠진 채로 둔다.
  """
  def stats(video_ids) when is_list(video_ids) do
    if configured?() do
      video_ids
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.chunk_every(@batch)
      |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
        case fetch(chunk) do
          {:ok, map} -> {:cont, {:ok, Map.merge(acc, map)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, "GOOGLE_API_KEY 가 없습니다. GCP 에서 YouTube Data API v3 를 켜고 API 키를 발급하세요."}
    end
  end

  defp fetch(ids) do
    params = [part: "statistics", id: Enum.join(ids, ","), key: api_key()]

    case Req.get(@endpoint, params: params, retry: :transient, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, "YouTube API #{status}: #{describe_error(body)}"}

      {:error, reason} ->
        {:error, "YouTube API 호출 실패: #{inspect(reason)}"}
    end
  end

  defp parse(%{"items" => items}) do
    Map.new(items, fn item ->
      s = item["statistics"] || %{}

      {item["id"],
       %{
         views: to_int(s["viewCount"]),
         likes: to_int(s["likeCount"]),
         comments: to_int(s["commentCount"])
       }}
    end)
  end

  defp parse(_), do: %{}

  defp describe_error(%{"error" => %{"message" => message}}), do: message
  defp describe_error(body), do: inspect(body) |> String.slice(0, 200)

  defp to_int(nil), do: 0

  defp to_int(value) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> 0
    end
  end

  @doc """
  유튜브 URL 이나 id 에서 영상 id 를 뽑는다.

  사용자는 주소창에서 복사해 붙인다. `youtu.be/xxx`, `watch?v=xxx`, `/shorts/xxx`,
  `/embed/xxx` 가 다 들어온다.
  """
  def video_id(nil), do: nil
  def video_id(""), do: nil

  def video_id(value) do
    # 구분자로 {} 를 쓰면 안 된다 — 수량자 {6,} 의 } 가 시길을 먼저 닫는다.
    patterns = [
      ~r"youtu\.be/([A-Za-z0-9_-]{6,})",
      ~r"[?&]v=([A-Za-z0-9_-]{6,})",
      ~r"/shorts/([A-Za-z0-9_-]{6,})",
      ~r"/embed/([A-Za-z0-9_-]{6,})",
      ~r"/live/([A-Za-z0-9_-]{6,})"
    ]

    found =
      Enum.find_value(patterns, fn re ->
        case Regex.run(re, value) do
          [_, id] -> id
          _ -> nil
        end
      end)

    cond do
      found -> found
      # URL 이 아니라 id 를 그대로 넣은 경우
      Regex.match?(~r"^[A-Za-z0-9_-]{6,}$", value) -> value
      true -> nil
    end
  end
end