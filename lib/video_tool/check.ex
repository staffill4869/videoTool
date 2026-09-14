defmodule VideoTool.Check do
  @moduledoc """
  발행하기 전에 완성본을 스스로 검사한다.

  왜 필요한가: 무인 루프는 자기가 만든 것을 다시 보지 않는다. 오늘 하루에 잡힌 것들 —
  음성이 화면보다 2.3초 앞섬, 썸네일이 세로, 자막에 `젫`, 장면이 16개 — 은 **전부 사람이
  영상을 열어 보고 지적해서야** 고쳐졌다. 그런데 넷 다 기계로 판정할 수 있는 것들이었다.

  여기 있는 검사는 전부 **실제로 나갔던 사고**에서 왔다. 추측으로 만든 항목은 없다.
  통과 못 해도 막지는 않는다 — 무엇이 이상한지 알려주고 판단은 부르는 쪽이 한다.
  """

  alias VideoTool.{Media, Projects}

  @doc "이 편이 나갈 만한지 본다. `%{pass: bool, checks: [...]}`"
  def run(project) do
    checks =
      [
        alignment(project),
        audio_matches_script(project),
        clip_coverage(project),
        subtitle_text(project),
        thumbnail(project),
        length_match(project)
      ]
      |> Enum.reject(&is_nil/1)

    %{
      pass: Enum.all?(checks, & &1.ok),
      failed: Enum.count(checks, &(not &1.ok)),
      checks: checks
    }
  end

  # ── 정렬 ────────────────────────────────────────────────────────
  # scene_secs 를 안 넘기면 "장면마다 음성이 클립과 같은 8초" 로 가정한 시간표가 만들어진다.
  # 실제 대사는 6.1~8.9초라 장면마다 밀리고 누적된다 (실측 55번: 5번 장면에서 2.3초).
  defp alignment(project) do
    case Media.latest_narration(project.id) do
      nil ->
        fail("정렬", "나레이션이 없습니다")

      %{scene_timing: timing} when is_list(timing) and timing != [] ->
        if Enum.any?(timing, &(&1["mode"] == "tight")) do
          ok("정렬", "장면별 음성 길이로 맞춰져 있습니다 (tight)")
        else
          fail(
            "정렬",
            "장면마다 클립 길이(8초)로 잘려 있습니다. 실제 대사 길이와 달라 뒤로 갈수록 밀립니다 — " <>
              "work/tts/sNN.mp3 를 두고 save_narration 을 다시 부르세요"
          )
        end

      _ ->
        fail("정렬", "장면 시간표가 없습니다")
    end
  end

  # ── 음성이 지금 대본으로 만든 것인가 ───────────────────────────
  #
  # 대본을 고친 뒤 음성을 다시 안 만들면, **자막은 새 대본이고 음성은 옛 대본**이 된다.
  # 실측(55번): 음성은 v1 로 만들었는데 자막은 v3 였다. 장면 4 는 음성이 42자짜리를 읽는데
  # 자막에는 27자가 떠 있었고, 장면 8 은 반대였다. 그대로 발행됐다.
  #
  # 어느 대본으로 읽었는지는 파일에 안 적혀 있다. 대신 **글자 수로 추정한 길이와 실제 음성
  # 길이**를 장면마다 비교한다. 같은 글을 읽었으면 붙어 있고, 다른 글이면 벌어진다.
  defp audio_matches_script(project) do
    dir = Path.join(["projects", "#{project.id}", "work", "tts"])
    cps = (project.voice && project.voice.chars_per_sec) || 5.0

    # **자막 줄이 아니라 장면 글로 비교한다.** 자막은 문장 단위로 쪼개져서 장면보다 줄이 많다
    # (8장면에 12줄). 번호로 맞추면 3번째부터 어긋나서, 멀쩡한 편을 틀렸다고 잡는다.
    with script when not is_nil(script) <- Projects.active_script(project.id),
         segments when segments != [] <- Projects.segments_for(script.id),
         files when files != [] <- Path.wildcard(Path.join(dir, "s*.mp3")) do
      by_scene = Map.new(segments, &{&1.scene_no, &1.text})

      gaps =
        files
        |> Enum.flat_map(fn f ->
          with [_, no] <- Regex.run(~r/s(\d+)\./, Path.basename(f)),
               scene_no <- String.to_integer(no),
               text when not is_nil(text) <- by_scene[scene_no],
               {:ok, actual} <- VideoTool.Ffmpeg.duration(f) do
            want = String.length(String.replace(text, " ", "")) / cps
            [{scene_no, abs(want - actual)}]
          else
            _ -> []
          end
        end)

      worst = gaps |> Enum.max_by(&elem(&1, 1), fn -> {0, 0.0} end)

      cond do
        gaps == [] -> nil
        elem(worst, 1) > 2.5 -> fail("대본↔음성", "장면 #{elem(worst, 0)} 에서 #{r(elem(worst, 1))}초 차이 — 대본을 고친 뒤 음성을 다시 안 만든 것 같습니다")
        true -> ok("대본↔음성", "같은 대본으로 읽혔습니다")
      end
    else
      _ -> nil
    end
  end

  # ── 클립이 장면 수만큼 있나 ─────────────────────────────────────
  defp clip_coverage(project) do
    scenes = length(Projects.scenes(project.id))
    clips = Media.list_assets(project.id, "clip") |> Enum.count(& &1.scene_id)

    cond do
      scenes == 0 -> fail("클립", "장면이 없습니다")
      clips >= scenes -> ok("클립", "#{clips}/#{scenes} 장면")
      true -> fail("클립", "#{clips}/#{scenes} 장면만 배정됐습니다. 빠진 장면은 화면이 비어 나갑니다")
    end
  end

  # ── 자막 글자 ───────────────────────────────────────────────────
  # 대본에는 "젖을" 인데 자막에는 "젫을" 이 들어가 그대로 구워져 나갔다. 대본과 자막은
  # 따로 저장돼서 서로 어긋날 수 있다. **대본에 한 번도 안 나온 글자**가 자막에 있으면 의심한다.
  defp subtitle_text(project) do
    with narration when not is_nil(narration) <- Media.latest_narration(project.id),
         script when not is_nil(script) <- Projects.active_script(project.id) do
      lines = Media.subtitles(narration.id) |> Enum.map(& &1.text)
      known = MapSet.new(String.graphemes(script.raw_text))

      strays =
        lines
        |> Enum.flat_map(&String.graphemes/1)
        |> Enum.filter(&(hangul?(&1) and not MapSet.member?(known, &1)))
        |> Enum.uniq()

      missing_q = Enum.filter(lines, &question_without_mark?/1)

      cond do
        strays != [] ->
          fail("자막", "대본에 없는 글자가 자막에 있습니다: #{Enum.join(strays, " ")} — 오타일 수 있습니다")

        missing_q != [] ->
          fail(
            "자막",
            "물음표가 빠진 의문문 #{length(missing_q)}개: #{List.first(missing_q)} — " <>
              "문장 끝 기호로 자막을 나누므로 두 문장이 한 줄로 붙습니다"
          )

        lines == [] ->
          fail("자막", "자막이 없습니다")

        true ->
          ok("자막", "#{length(lines)}줄, 이상 없음")
      end
    else
      _ -> fail("자막", "대본이나 나레이션이 없습니다")
    end
  end

  defp hangul?(<<c::utf8>>), do: c >= 0xAC00 and c <= 0xD7A3
  defp hangul?(_), do: false

  defp question_without_mark?(line) do
    String.match?(line, ~r/(까요|나요|을까|ㄹ까|는가|느냐|어떤가)\s*\.$/u)
  end

  # ── 썸네일 ──────────────────────────────────────────────────────
  # 그려 놓고 save_thumbnail 을 안 불러 "섬네일 없음" 으로 올라갔고,
  # 그 다음엔 세로(9:16)로 그려서 올라갔다. 유튜브 썸네일은 가로다.
  defp thumbnail(project) do
    case Media.latest_render(project.id, project.aspect) do
      nil ->
        nil

      render ->
        path = if render.thumbnail_path != "", do: render.thumbnail_path

        cond do
          is_nil(path) or not File.exists?(path) ->
            fail("썸네일", "붙어 있지 않습니다. save_thumbnail 을 부르세요 (파일만 폴더에 두면 안 됩니다)")

          true ->
            case VideoTool.Ffmpeg.probe(path) do
              {:ok, %{width: w, height: h}} when w > h -> ok("썸네일", "#{w}x#{h} 가로")
              {:ok, %{width: w, height: h}} -> fail("썸네일", "#{w}x#{h} — 세로입니다. 유튜브 썸네일은 가로(16:9)여야 합니다")
              _ -> ok("썸네일", "있습니다 (크기를 못 읽음)")
            end
        end
    end
  end

  # ── 영상 길이와 나레이션 길이 ───────────────────────────────────
  # 대본이 영상보다 짧으면 뒤가 통째로 무음이 된다 (실측: 영상 120초 / 나레이션 67초).
  defp length_match(project) do
    with render when not is_nil(render) <- Media.latest_render(project.id, project.aspect),
         narration when not is_nil(narration) <- Media.latest_narration(project.id),
         {:ok, video} <- VideoTool.Ffmpeg.duration(render.file_path) do
      silent = video - (narration.duration_sec || 0)

      if silent > 5 do
        fail("길이", "영상 #{r(video)}초 / 나레이션 #{r(narration.duration_sec)}초 — 뒤 #{r(silent)}초가 무음입니다")
      else
        ok("길이", "영상 #{r(video)}초 / 나레이션 #{r(narration.duration_sec)}초")
      end
    else
      _ -> nil
    end
  end

  defp r(nil), do: "?"
  defp r(n), do: Float.round(n * 1.0, 1)

  defp ok(name, detail), do: %{name: name, ok: true, detail: detail}
  defp fail(name, detail), do: %{name: name, ok: false, detail: detail}
end
