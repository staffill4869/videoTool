defmodule VideoTool.Grants do
  @moduledoc """
  **기업마당 지원사업 공고** — 정부·지자체가 지금 받고 있는 지원사업.

  영상 주제로 쓰려고 붙였다. 에이전트가 목록을 보고 한 건을 골라
  `run_series(topic: ...)` 의 주제로 넣으면 그 뒤는 평소 파이프라인과 같다.

  **표를 만들지 않는다.** personalCRM 은 1,620건을 새벽마다 통째로 받아 저장하지만
  (회사마다 맞는 공고를 골라야 해서), 여기서 필요한 건 "요즘 뭐가 올라왔나" 뿐이다.
  부를 때마다 최신 몇 건만 받는다 — `searchCnt` 로 개수가 조절된다.

  **숫자는 요약에 없는 게 많다.** 지원금액·자격요건은 대부분 첨부 공고문(`attachment`)
  안에 있다. 대본에 금액을 쓰려면 그 파일을 열어 확인하고 `save_allowed_facts` 에
  넣어야 한다 — 요약만 보고 쓰면 지어낸 숫자가 나간다.
  """

  @api_url "https://www.bizinfo.go.kr/uss/rss/bizinfoApi.do"
  @file_base "https://www.bizinfo.go.kr"

  @doc """
  최신 공고 목록.

  opts:
    * `:limit` — 받을 건수 (기본 20). 0 이면 전부(1,600여 건 · 3.8MB)라 쓰지 마라.
    * `:query` — 제목·요약·해시태그에 이 말이 든 것만. 받아온 것 안에서 거른다.
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    query = opts |> Keyword.get(:query) |> blank()

    # 거를 거면 넉넉히 받아야 한다 — 받은 20건 안에 그 말이 없으면 빈손이 된다.
    fetch_count = if query, do: max(limit * 20, 300), else: limit

    with {:ok, key} <- api_key(),
         {:ok, items} <- fetch(key, fetch_count) do
      rows =
        items
        |> Enum.map(&from_api/1)
        |> Enum.reject(&is_nil/1)
        |> filter(query)
        |> Enum.take(limit)

      {:ok, rows}
    end
  end

  defp api_key do
    case Application.get_env(:video_tool, :bizinfo_api_key) do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        {:error, "기업마당 키가 없습니다. .env 에 BIZINFO_API_KEY 를 넣고 서버를 다시 켜세요."}
    end
  end

  defp fetch(key, count) do
    case Req.get(@api_url,
           params: [crtfcKey: key, dataType: "json", searchCnt: count],
           receive_timeout: :timer.minutes(2)
         ) do
      {:ok, %{status: 200, body: %{"jsonArray" => items}}} when is_list(items) ->
        {:ok, items}

      {:ok, %{status: status}} ->
        {:error, "기업마당 응답 오류 (#{status})"}

      {:error, reason} ->
        {:error, "기업마당에 연결하지 못했습니다: #{inspect(reason)}"}
    end
  end

  defp filter(rows, nil), do: rows

  defp filter(rows, query) do
    q = String.downcase(query)

    Enum.filter(rows, fn r ->
      [r.title, r.summary, r.agency, Enum.join(r.hashtags, " ")]
      |> Enum.reject(&is_nil/1)
      |> Enum.any?(&String.contains?(String.downcase(&1), q))
    end)
  end

  @doc false
  def from_api(%{"pblancId" => id, "pblancNm" => title} = item)
      when is_binary(id) and id != "" and is_binary(title) do
    period = blank(item["reqstBeginEndDe"])

    %{
      id: id,
      title: String.trim(title),
      agency: blank(item["jrsdInsttNm"]),
      realm: blank(item["pldirSportRealmLclasCodeNm"]),
      target: blank(item["trgetNm"]),
      period: period,
      ends_on: ends_on(period),
      summary: plain(item["bsnsSumryCn"]),
      how_to_apply: plain(item["reqstMthPapersCn"]),
      hashtags: tags(item["hashtags"]),
      url: blank(item["pblancUrl"]),
      # 금액·자격은 대부분 여기 들어 있다. 대본에 숫자를 쓰려면 이걸 열어야 한다.
      attachment: attachment(item["printFlpthNm"])
    }
  end

  def from_api(_), do: nil

  # 「2026-09-16 ~ 2026-10-02」 의 뒷날짜. 「예산 소진시까지」·「상시 접수」 면 nil.
  defp ends_on(nil), do: nil

  defp ends_on(period) do
    with [iso] <- Regex.scan(~r/\d{4}-\d{2}-\d{2}/, period) |> List.last(),
         {:ok, date} <- Date.from_iso8601(iso) do
      date
    else
      _ -> nil
    end
  end

  defp attachment(path) when is_binary(path) do
    case String.trim(path) do
      "" -> nil
      "http" <> _ = url -> url
      "/" <> _ = p -> @file_base <> p
      p -> @file_base <> "/" <> p
    end
  end

  defp attachment(_), do: nil

  defp tags(text) when is_binary(text),
    do: text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp tags(_), do: []

  # 사업 개요는 HTML 로 온다.
  defp plain(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~w(&nbsp; &lt; &gt; &quot; &amp;), fn
      "&nbsp;" -> " "
      "&lt;" -> "<"
      "&gt;" -> ">"
      "&quot;" -> "\""
      "&amp;" -> "&"
    end)
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> blank()
  end

  defp plain(_), do: nil

  defp blank(nil), do: nil

  defp blank(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      t -> t
    end
  end

  defp blank(_), do: nil
end
