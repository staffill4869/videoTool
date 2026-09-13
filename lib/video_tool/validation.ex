defmodule VideoTool.Validation do
  @moduledoc """
  단계별 검증. 통과해야 `next/1` 이 다음 단계로 넘어간다.

  **못 돌린 검사를 통과로 기록하지 않는다.** 허용 수치 검증은 OCR 이 있어야만 성립하는데,
  tesseract 가 없다고 그냥 통과시키면 이 기능이 존재하는 이유(화면에 없는 숫자가 렌더링된 사고)가
  통째로 무의미해진다. 그래서 `skipped_no_ocr` 로 남기고 경고로 올린다.
  """

  alias VideoTool.{Jobs, Media, Ocr, Projects}

  @clip_target_sec 8.0
  @clip_tolerance 0.2
  @aspect_tolerance 0.02

  @doc "검증하고 결과를 기록한다. {:ok, %{passed:, checks:, problems:, warnings:}}."
  def run(project, stage) do
    result = check(project, stage)

    {:ok, _} =
      Jobs.record_validation(project.id, stage, result.passed, result.checks, result.problems)

    {:ok, result}
  end

  # ── CLEAN ───────────────────────────────────────────────────────

  defp check(project, "clean") do
    scenes = Projects.scenes(project.id)
    assets = Media.list_assets(project.id, "clean")

    problems =
      count_problems(scenes, assets, "CLEAN") ++
        aspect_problems(project, assets) ++
        unmapped_problems(assets) ++
        duplicate_problems(assets)

    finish(
      %{
        "count" => length(assets) == length(scenes),
        "aspect" => aspect_problems(project, assets) == [],
        "all_mapped" => unmapped_problems(assets) == [],
        "no_duplicates" => duplicate_problems(assets) == []
      },
      problems,
      []
    )
  end

  # ── INFO ────────────────────────────────────────────────────────

  defp check(project, "info") do
    scenes = Projects.scenes(project.id)
    cleans = Media.list_assets(project.id, "clean")
    assets = Media.list_assets(project.id, "info")

    pairing =
      if length(assets) == length(cleans),
        do: [],
        else: [%{"scene_no" => nil, "issue" => "INFO #{length(assets)}장 / CLEAN #{length(cleans)}장 — 1:1 이 아닙니다"}]

    base =
      count_problems(scenes, assets, "INFO") ++
        pairing ++
        aspect_problems(project, assets) ++
        unmapped_problems(assets)

    {ocr_checks, ocr_problems, warnings} = ocr_checks(project, assets)

    finish(
      Map.merge(
        %{
          "count" => length(assets) == length(scenes),
          "pairs_with_clean" => pairing == [],
          "aspect" => aspect_problems(project, assets) == [],
          "all_mapped" => unmapped_problems(assets) == []
        },
        ocr_checks
      ),
      base ++ ocr_problems,
      warnings
    )
  end

  # ── 클립 ────────────────────────────────────────────────────────

  defp check(project, "clips") do
    scenes = Projects.scenes(project.id)
    assets = Media.list_assets(project.id, "clip")

    duration =
      assets
      |> Enum.filter(fn a ->
        d = a.duration_sec || 0.0
        abs(d - @clip_target_sec) > @clip_tolerance
      end)
      |> Enum.map(fn a ->
        %{
          "scene_no" => scene_no(a),
          "issue" => "길이 #{fmt(a.duration_sec)}초 (기대 #{@clip_target_sec}±#{@clip_tolerance})"
        }
      end)

    chain =
      assets
      |> Enum.filter(&(&1.phash_last == ""))
      |> Enum.map(&%{"scene_no" => scene_no(&1), "issue" => "마지막 프레임 해시가 없습니다"})

    problems =
      count_problems(scenes, assets, "클립") ++
        aspect_problems(project, assets) ++
        unmapped_problems(assets) ++ duration ++ chain

    finish(
      %{
        "count" => length(assets) == length(scenes),
        "duration" => duration == [],
        "aspect" => aspect_problems(project, assets) == [],
        "all_mapped" => unmapped_problems(assets) == [],
        "frame_chain" => chain == []
      },
      problems,
      []
    )
  end

  # ── 최종본 ──────────────────────────────────────────────────────

  defp check(project, "final") do
    narration = Media.latest_narration(project.id)
    render = Media.latest_render(project.id, project.aspect)

    cond do
      is_nil(render) ->
        finish(%{"render_exists" => false}, [%{"scene_no" => nil, "issue" => "완성본이 없습니다"}], [])

      is_nil(narration) ->
        finish(%{"narration_exists" => false}, [%{"scene_no" => nil, "issue" => "나레이션이 없습니다"}], [])

      true ->
        gap = abs(render.duration_sec - narration.duration_sec)
        subtitles = Media.subtitles(narration.id)

        problems =
          [
            {gap > 2.0, "완성본 #{fmt(render.duration_sec)}초 / 나레이션 #{fmt(narration.duration_sec)}초 — 2초를 넘게 어긋납니다"},
            {subtitles == [], "자막이 하나도 없습니다"}
          ]
          |> Enum.filter(&elem(&1, 0))
          |> Enum.map(&%{"scene_no" => nil, "issue" => elem(&1, 1)})

        finish(
          %{
            "render_exists" => true,
            "narration_exists" => true,
            "duration_match" => gap <= 2.0,
            "subtitles" => subtitles != []
          },
          problems,
          []
        )
    end
  end

  # ── 공통 검사 ───────────────────────────────────────────────────

  defp count_problems(scenes, assets, label) do
    if length(assets) == length(scenes) do
      []
    else
      [%{"scene_no" => nil, "issue" => "#{label} #{length(assets)}개 (장면 #{length(scenes)}개와 다릅니다)"}]
    end
  end

  defp aspect_problems(project, assets) do
    expected = aspect_ratio(project.aspect)

    assets
    |> Enum.filter(fn a ->
      a.height > 0 and abs(a.width / a.height - expected) > @aspect_tolerance
    end)
    |> Enum.map(fn a ->
      %{"scene_no" => scene_no(a), "issue" => "화면비 #{a.width}x#{a.height} (기대 #{project.aspect})"}
    end)
  end

  defp unmapped_problems(assets) do
    assets
    |> Enum.filter(&is_nil(&1.scene_id))
    |> Enum.map(&%{"scene_no" => nil, "issue" => "장면에 매핑되지 않았습니다: #{Path.basename(&1.file_path)}"})
  end

  defp duplicate_problems(assets) do
    assets
    |> Enum.filter(& &1.scene_id)
    |> Enum.frequencies_by(& &1.scene_id)
    |> Enum.filter(fn {_scene_id, n} -> n > 1 end)
    |> Enum.map(fn {scene_id, n} ->
      %{"scene_no" => scene_no_of(assets, scene_id), "issue" => "한 장면에 #{n}개가 붙었습니다"}
    end)
  end

  # ── OCR 이 필요한 검사 ──────────────────────────────────────────

  defp ocr_checks(project, assets) do
    if Ocr.available?() do
      allowed =
        project.id
        |> Projects.active_script()
        |> then(&(&1 && &1.id))
        |> Projects.allowed_facts()
        |> Enum.map(& &1.value)

      results =
        Enum.map(assets, fn asset ->
          case Ocr.text(asset.file_path) do
            {:ok, text} -> {asset, text}
            {:error, reason} -> {asset, {:error, reason}}
          end
        end)

      problems =
        Enum.flat_map(results, fn
          {asset, {:error, reason}} ->
            [%{"scene_no" => scene_no(asset), "issue" => "OCR 실행 실패: #{reason}"}]

          {asset, text} ->
            unreadable(asset, text) ++
              whitelist_problems(asset, text, allowed) ++ legibility_problems(asset, text)
        end)

      {%{"allowed_facts" => problems == [], "legibility" => true}, problems, []}
    else
      {%{"allowed_facts" => "skipped_no_ocr", "legibility" => "skipped_no_ocr"}, [],
       [
         "tesseract 가 없어 허용 수치 검증을 못 했습니다. 화면에 대본에 없는 숫자가 있어도 " <>
           "잡히지 않습니다 — `scoop install tesseract` 후 kor 언어 데이터를 넣으세요."
       ]}
    end
  end

  # 라벨이 있어야 하는 컷에서 OCR 이 한 글자도 못 읽었다면, 그건 "문제 없음" 이 아니라
  # "확인 못 함" 이다. 그대로 통과시키면 화면에 지어낸 숫자가 있어도 검증이 초록불을 켠다.
  defp unreadable(asset, text) do
    cond do
      Ocr.legible?(text) -> []
      expected_labels(asset) == [] -> []
      true -> [%{"scene_no" => scene_no(asset), "issue" => "OCR 이 아무 글자도 못 읽어 수치 검증을 못 했습니다"}]
    end
  end

  defp expected_labels(%{scene: %{expected_labels: labels}}), do: labels || []
  defp expected_labels(_), do: []

  defp whitelist_problems(asset, text, allowed) do
    case Ocr.out_of_whitelist(text, allowed) do
      [] -> []
      found -> [%{"scene_no" => scene_no(asset), "issue" => "허용 외 수치 #{inspect(found)}"}]
    end
  end

  # 한글이 깨지면 대체문자나 낱자 자모가 남는다.
  defp legibility_problems(asset, text) do
    if String.match?(text, ~r/[\x{FFFD}\x{3131}-\x{318E}]/u) do
      [%{"scene_no" => scene_no(asset), "issue" => "한글이 깨져 보입니다 (자모 분리 또는 대체문자)"}]
    else
      []
    end
  end

  # ── 도우미 ──────────────────────────────────────────────────────

  defp finish(checks, problems, warnings) do
    # 못 돌린 검사(skipped_*)는 통과 판정에 넣지 않는다.
    ran = checks |> Map.values() |> Enum.filter(&is_boolean/1)

    %{
      passed: problems == [] and Enum.all?(ran),
      checks: checks,
      problems: problems,
      warnings: warnings
    }
  end

  defp aspect_ratio("9:16"), do: 9 / 16
  defp aspect_ratio(_), do: 16 / 9

  defp scene_no(%{scene: %{scene_no: n}}), do: n
  defp scene_no(_), do: nil

  defp scene_no_of(assets, scene_id) do
    assets |> Enum.find(&(&1.scene_id == scene_id)) |> scene_no()
  end

  defp fmt(nil), do: "?"
  defp fmt(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 2)
  defp fmt(n), do: to_string(n)
end