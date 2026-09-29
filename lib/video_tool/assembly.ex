defmodule VideoTool.Assembly do
  @moduledoc """
  나레이션 정렬과 최종 합성. 설명서 4주차(§5.3 무음 정렬, §5.4 리타이밍, §5.5 합성).

  여기에는 LLM 이 없다. 에이전트가 만든 음성 파일을 받아서 기계적인 일만 한다 —
  길이 재기, 무음 찾기, 장면에 시간 나눠주기, 자막 만들기, ffmpeg 으로 붙이기.
  """

  require Logger

  alias VideoTool.{Ffmpeg, Media, Projects}

  # 나레이션이 영상보다 길거나 짧을 때 장면 하나를 얼마나 늘리고 줄일지의 한계.
  # 이 범위를 벗어나면 배속으로 맞추지 않고 다른 수단을 쓴다 — 배속이 티가 나기 때문이다.
  #
  # 아래쪽 한계를 0.85 → 0.62 로 내렸다(2026-09-23, 속도감 요청).
  # Flow 는 무조건 8초 클립을 낸다. 장면을 5.5초로 잡으면 f = 0.69 인데, 0.85 기준이면
  # **배속이 아니라 앞을 2.5초 잘라냈다** — 카메라 움직임의 3분의 1이 사라질 뿐
  # 빨라지지는 않는다. 0.62 로 내리면 8초가 5.5초로 **1.45배속**돼 같은 움직임이 빠르게 간다.
  # 더 내리면(=1.6배 이상) 배속이 눈에 띄기 시작하므로 거기서 멈춘다.
  @speed_min 0.62
  @speed_max 1.35

  # 마지막 장면에 남기는 여운. 0 이면 말 끝나자마자 뚝 끊기고, 길면 무음이 남는다.
  @last_tail_sec 1.0

  # ── 나레이션 저장 · 정렬 ────────────────────────────────────────

  @doc """
  에이전트가 만든 음성 파일을 프로젝트에 등록하고 장면 시간을 계산한다.

  `src` 는 로컬 경로 또는 http(s) URL.
  """
  def save_narration(project, src), do: save_narration(project, src, [])

  def save_narration(project, src, opts) do
    with {:ok, script} <- fetch_script(project),
         {:ok, path} <- place_audio(project, src),
         {:ok, duration} <- Ffmpeg.duration(path),
         {:ok, silences} <- Ffmpeg.silences(path) do
      segments = Projects.segments_for(script.id)
      # 클립이 다 있으면 **클립 길이가 곧 장면 시간**이다. 글자 수 비례로 나누면
      # 영상은 8초씩 가는데 자막은 6초씩 가서 장면마다 어긋난다 (실측: 4번째에서 9초).
      timing =
        narration_timing(project, opts[:scene_secs]) ||
          clip_timing(project) || scene_timing(segments, duration, silences)
      cps = measured_cps(segments, duration)

      attrs = %{
        project_id: project.id,
        script_id: script.id,
        voice_id: project.voice_id,
        file_path: path,
        duration_sec: duration,
        provider: "higgsfield",
        silence_segments: silences,
        scene_timing: timing,
        measured_chars_per_sec: cps
      }

      with {:ok, narration} <- Media.create_narration(attrs) do
        rows = subtitle_rows(segments, timing)
        {:ok, _} = Media.replace_subtitles(narration, rows)

        {:ok,
         %{
           narration_id: narration.id,
           duration_sec: duration,
           silence_count: length(silences),
           scenes: length(timing),
           subtitles: length(rows),
           measured_chars_per_sec: cps,
           file_path: path
         }}
      end
    end
  end

  @doc """
  장면 시간을 **클립 실측 길이**에서 뽑는다. 클립이 장면마다 하나씩 다 있을 때만.

  이게 정렬의 핵심이다. 영상은 클립을 그대로 이어 붙이므로 장면 N 의 화면은
  앞선 클립들의 길이 합에서 시작한다. 자막과 나레이션도 같은 축을 써야 맞는다.
  """
  def clip_timing(project) do
    scenes = Projects.scenes(project.id)
    by_scene = clips_by_scene(project)

    # 클립이 붙은 장면만 쓴다. 전부 있어야만 동작하게 두면 한 장면만 비어도
    # 정렬이 통째로 옛 방식(글자 수 비례)으로 되돌아간다.
    usable = Enum.filter(scenes, &Map.has_key?(by_scene, &1.id))

    if length(usable) >= max(div(length(scenes) * 9, 10), 1) do
      {rows, _} =
        Enum.map_reduce(usable, 0.0, fn scene, cursor ->
          d = by_scene[scene.id].duration_sec || 0.0
          stop = Float.round(cursor + d, 3)

          {%{
             "scene_id" => scene.id,
             "start" => Float.round(cursor, 3),
             "end" => stop,
             "target_sec" => Float.round(d, 3)
           }, stop}
        end)

      rows
    end
  end

  @doc """
  장면 뒤에 남는 무음을 없앤다.

  장면마다 클립(8초)이 나레이션(5초)보다 길면 그 차이가 통째로 무음으로 남았다.
  여기서는 각 장면의 화면 길이를 **그 장면 나레이션 길이**로 잡아 뒤를 잘라내고,
  **마지막 장면만 클립을 통째로** 남긴다 (끝맺음 여운은 있어야 한다).

  `scene_secs` 는 장면 번호 → 그 장면 음성 길이(초).

  **안 넘겨주면 디스크에서 직접 잰다.** 예전에는 조용히 `clip_timing`(장면마다 클립 길이
  = 8초)으로 떨어졌는데, 실제 대사는 6.1~8.9초로 들쭉날쭉해서 장면마다 최대 0.9초씩 밀리고
  그게 **누적된다** — 실측(55번): 5번 장면에서 음성이 화면보다 2.3초 앞서 갔고 그대로 발행됐다.
  장면별 음성은 `work/tts/s01.mp3` 규칙으로 이미 디스크에 있다. 안 넘겨줬다고 틀린 시간표를
  쓰느니 파일을 재는 게 맞다.
  """
  def narration_timing(project, nil) do
    case measure_scene_tts(project) do
      nil -> nil
      secs -> narration_timing(project, secs)
    end
  end

  def narration_timing(project, secs) when secs == %{}, do: narration_timing(project, nil)

  def narration_timing(project, secs) when is_map(secs) do
    scenes = Projects.scenes(project.id)
    by_scene = clips_by_scene(project)
    usable = Enum.filter(scenes, &Map.has_key?(by_scene, &1.id))
    last = List.last(usable)

    if usable != [] do
      {rows, _} =
        Enum.map_reduce(usable, 0.0, fn scene, cursor ->
          clip = by_scene[scene.id].duration_sec || 0.0
          spoken = secs[to_string(scene.scene_no)] || secs[scene.scene_no]
          # 마지막 장면은 통째로. 음성이 없는 장면도 클립 길이 그대로 둔다.
          # **클립보다 길게 잡지 않는다.** 8초짜리에 8.5초를 요구하면 잘라 봐야 8초만 나오고,
          # 시간표만 0.5초 앞서 가서 그 차이가 뒤로 계속 쌓인다 (드리프트의 정체다).
          # 마지막 장면도 **여운만** 주고 자른다.
          # 예전에는 클립을 통째로 남겼는데(8초), 대사가 3초면 5초가 무음으로 남았다.
          # 쇼츠에서 그 구간은 그냥 이탈이고, `validate(final)` 도 "완성본과 나레이션이
          # 2초 넘게 어긋난다"로 발행을 막는다(실측 2026-09-23, 77번: 42.2 vs 37.4).
          d =
            cond do
              is_nil(spoken) -> clip
              scene.id == last.id -> min(spoken + @last_tail_sec, clip)
              true -> min(spoken * 1.0, clip)
            end
          stop = Float.round(cursor + d, 3)

          {%{
             "scene_id" => scene.id,
             "start" => Float.round(cursor, 3),
             "end" => stop,
             "target_sec" => Float.round(d, 3),
             "mode" => "tight"
           }, stop}
        end)

      rows
    end
  end

  # 장면별 TTS 는 work/tts/s01.mp3 규칙으로 떨어져 있다. 부르는 쪽이 길이를 안 넘겨주면
  # 여기서 직접 잰다 — 안 넘겨줬다는 이유로 틀린 시간표를 쓰는 것보다 낫다.
  defp measure_scene_tts(project) do
    dir = Path.join([work_dir(project), "work", "tts"])

    case Path.wildcard(Path.join(dir, "s*.mp3")) ++ Path.wildcard(Path.join(dir, "s*.wav")) do
      [] ->
        nil

      files ->
        files
        |> Enum.flat_map(fn f ->
          # 파일은 s01 인데 장면 번호는 1 이다. 앞자리 0 을 떼지 않으면 키가 안 맞아
          # 조용히 예전 방식(클립 길이)으로 떨어진다 — mode 만 tight 로 찍히고 시간은 그대로였다.
          with [_, no] <- Regex.run(~r/s(\d+)\./, Path.basename(f)),
               {:ok, d} <- Ffmpeg.duration(f) do
            [{no |> String.to_integer() |> Integer.to_string(), d}]
          else
            _ -> []
          end
        end)
        |> case do
          [] -> nil
          pairs -> Map.new(pairs)
        end
    end
  end

  defp clips_by_scene(project) do
    Media.list_assets(project.id, "clip")
    |> Enum.filter(& &1.scene_id)
    |> Enum.group_by(& &1.scene_id)
    |> Map.new(fn {sid, list} -> {sid, Enum.max_by(list, & &1.order_confidence)} end)
  end

  defp fetch_script(project) do
    case Projects.active_script(project.id) do
      nil -> {:error, "대본이 없습니다. save_script 를 먼저 하세요."}
      script -> {:ok, script}
    end
  end

  defp place_audio(project, src) do
    dir = work_dir(project)
    File.mkdir_p!(dir)
    dest = Path.join(dir, "narration#{ext(src)}")

    cond do
      String.starts_with?(src, "http") -> download(src, dest)
      File.exists?(src) -> copy(src, dest)
      true -> {:error, "음성 파일을 찾을 수 없습니다: #{src}"}
    end
  end

  defp ext(src) do
    case src |> URI.parse() |> Map.get(:path) |> to_string() |> Path.extname() do
      "" -> ".wav"
      e -> e
    end
  end

  defp copy(src, dest) do
    # 같은 파일을 자기 자신에 덮어쓰면 0바이트가 된다.
    if Path.expand(src) == Path.expand(dest) do
      {:ok, dest}
    else
      case File.cp(src, dest) do
        :ok -> {:ok, dest}
        {:error, r} -> {:error, "음성 파일 복사 실패: #{inspect(r)}"}
      end
    end
  end

  defp download(url, dest) do
    case System.cmd("curl", ["-sL", "--fail", url, "-o", dest], stderr_to_stdout: true) do
      {_, 0} -> if File.exists?(dest), do: {:ok, dest}, else: {:error, "내려받기 후 파일이 없습니다"}
      {out, code} -> {:error, "내려받기 실패 (exit #{code}): #{String.slice(out, 0, 200)}"}
    end
  rescue
    e in ErlangError -> {:error, "curl 을 실행할 수 없습니다: #{inspect(e.original)}"}
  end

  @doc """
  장면마다 나레이션의 어느 구간을 쓸지 정한다.

  글자 수 비례로 1차 배분한 뒤, 각 경계를 가장 가까운 무음 구간 한가운데로 당긴다.
  말 중간에서 장면이 바뀌면 티가 나기 때문이다. 가까운 무음이 없으면 그대로 둔다.
  """
  def scene_timing([], _duration, _silences), do: []

  def scene_timing(segments, duration, silences) do
    weights = Enum.map(segments, fn s -> max(String.length(s.text || ""), 1) end)
    total = Enum.sum(weights)

    # 누적 비율로 경계를 만든다 (0 과 duration 은 고정)
    {bounds, _} =
      Enum.map_reduce(weights, 0, fn w, acc ->
        acc = acc + w
        {Float.round(acc / total * duration, 3), acc}
      end)

    inner = bounds |> Enum.drop(-1) |> Enum.map(&snap(&1, silences, duration))
    edges = [0.0] ++ inner ++ [duration]

    edges
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.zip(segments)
    |> Enum.map(fn {[from, to], seg} ->
      %{
        "scene_id" => seg.scene_id,
        "start" => from,
        "end" => to,
        "target_sec" => Float.round(to - from, 3)
      }
    end)
  end

  # 무음 한가운데가 0.9초 안에 있으면 거기로 당긴다. 그보다 멀면 손대지 않는다 —
  # 억지로 당기면 장면 길이가 크게 흔들려 배속이 티가 난다.
  defp snap(t, silences, duration) do
    silences
    |> Enum.map(& &1["mid"])
    |> Enum.filter(&(&1 > 0.3 and &1 < duration - 0.3))
    |> Enum.min_by(&abs(&1 - t), fn -> nil end)
    |> case do
      nil -> t
      mid -> if abs(mid - t) <= 0.9, do: mid, else: t
    end
  end

  # estimate_length 는 공백을 뺀 글자 수로 센다. 여기서도 같은 기준으로 세야
  # 이 값을 보이스에 되먹였을 때 추정이 맞는다 — 공백을 넣으면 초당 글자수가 부풀려진다.
  defp measured_cps(segments, duration) when duration > 0 do
    chars =
      segments
      |> Enum.map(fn s -> s.text |> to_string() |> String.replace(~r/\s+/u, "") |> String.length() end)
      |> Enum.sum()

    Float.round(chars / duration, 2)
  end

  defp measured_cps(_, _), do: 0.0

  # 한 장면의 대사를 문장 단위로 쪼개 자막 줄을 만든다.
  # 문장 길이 비례로 시간을 나눈다 — 단어 단위 타임스탬프가 없으니 이게 최선이다.
  defp subtitle_rows(segments, timing) do
    by_scene = Map.new(timing, &{&1["scene_id"], &1})

    segments
    |> Enum.flat_map(fn seg ->
      case Map.get(by_scene, seg.scene_id) do
        nil -> []
        t -> split_lines(seg.text || "", t["start"], t["end"])
      end
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, i} -> Map.put(row, :index, i) end)
  end

  # 자막 한 줄의 최대 글자 수. 세로 1080 폭에 84pt 면 한 줄에 열두 자쯤 들어가므로
  # 이 값이면 두 줄을 넘지 않는다. 더 키우면 세 줄이 되어 화면을 덮는다.
  @sub_max_chars 18

  defp split_lines(text, from, to) do
    sentences =
      text
      |> String.split(~r/(?<=[.!?])\s+/u, trim: true)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.flat_map(&chunk/1)

    case sentences do
      [] -> []
      list -> allocate(list, from, to)
    end
  end

  @doc false
  # 긴 문장을 쉼표·띄어쓰기에서 잘라 짧은 토막으로 만든다.
  #
  # 예전에는 문장 부호에서만 끊었다. 한 장면이 8초인데 문장이 둘이면 한 줄이 4초씩
  # 떠 있어서, 읽고 나서도 한참 남는다. 짧게 끊어 넘겨야 눈이 따라간다.
  # **쉼표를 먼저 본다** — 말이 실제로 쉬는 자리라 여기서 끊으면 어색하지 않다.
  def chunk(sentence) do
    text = String.trim(sentence)

    if String.length(text) <= @sub_max_chars do
      [text]
    else
      case break_at(text) do
        nil -> [text]
        i -> [String.slice(text, 0, i) |> String.trim()] ++ chunk(String.slice(text, i..-1//1))
      end
    end
  end

  # 자를 자리. **가운데에 가까운 곳**을 고른다.
  #
  # 맨 뒤에서 자르면 남는 토막이 한 마디로 짧아진다 — "…고칠 값어치가" / "있을까요?" 처럼
  # 뒤가 0.75초만 떠서 읽히지 않는다(2026-09-29 실측). 반씩 나누면 둘 다 읽을 시간이 생긴다.
  # 다만 앞 토막이 @sub_max_chars 를 넘으면 줄이 세 줄이 되므로 거기서 멈춘다.
  defp break_at(text) do
    len = String.length(text)
    lo = div(len, 4)
    hi = min(@sub_max_chars, len - 1)
    target = min(div(len, 2), @sub_max_chars)

    find_mark(text, lo, hi, target, [",", "،", ";", ":"]) ||
      find_mark(text, lo, hi, target, [" "])
  end

  defp find_mark(text, lo, hi, target, marks) do
    lo..hi//1
    |> Enum.filter(&(String.at(text, &1) in marks))
    |> Enum.min_by(&abs(&1 - target), fn -> nil end)
    |> case do
      nil -> nil
      i -> i + 1
    end
  end

  defp allocate(list, from, to) do
    weights = Enum.map(list, &max(String.length(&1), 1))
    total = Enum.sum(weights)
    span = to - from

    {rows, _} =
      Enum.map_reduce(Enum.zip(list, weights), from, fn {text, w}, cursor ->
        stop = min(Float.round(cursor + span * w / total, 3), to)
        {%{start_sec: cursor, end_sec: stop, text: String.trim(text)}, stop}
      end)

    rows
  end

  # ── 합성 ────────────────────────────────────────────────────────

  @doc """
  클립을 장면 순서로 이어 붙이고 나레이션을 얹어 완성본을 만든다.

  자막은 하드번한다. 다만 **자막 없는 마스터를 함께 남긴다** — 세로본과
  다른 언어판이 그걸 다시 쓴다.
  """
  def assemble(project, opts \\ []) do
    dir = work_dir(project)
    File.mkdir_p!(Path.join(dir, "work"))

    # 프로젝트에 지정된 폰트가 우선. 없으면 기본값.
    font =
      Keyword.get(opts, :font) ||
        (project.subtitle_font not in [nil, ""] && project.subtitle_font) ||
        VideoTool.Presets.default_subtitle_font()

    # 화면비를 옵션으로 실어 내린다. 안 실으면 인코딩과 자막이 1920x1080 기준으로 돌아가
    # 세로 클립이 가로 판에 끼워진다 — 실측: 720x1280 클립이 1920x1080 으로 나왔다.
    opts =
      opts
      |> Keyword.put(:font, font)
      |> Keyword.put_new(:aspect, project.aspect || "16:9")

    with {:ok, narration} <- fetch_narration(project),
         {:ok, clips} <- fetch_clips(project),
         {:ok, plan} <- build_plan(clips, narration),
         opts = Keyword.put_new(opts, :fit, fit_mode(narration)),
         overlaps = seam_overlaps(project, plan, opts),
         {:ok, pieces} <- retime_all(plan, dir, opts, overlaps),
         {:ok, joined} <- dissolve(pieces, overlaps, dir, opts),
         {:ok, master} <- concat_and_mix(joined, narration, dir),
         {:ok, final} <- burn_subtitles(project, master, narration, dir, opts) do
      {:ok, probe} = Ffmpeg.probe(final)

      attrs = %{
        project_id: project.id,
        narration_id: narration.id,
        kind: "final",
        aspect: project.aspect || "16:9",
        file_path: final,
        duration_sec: probe.duration_sec || 0.0,
        burn_subtitles: final != master,
        settings: %{
          "master_no_subs" => master,
          "clips" => length(pieces),
          # 어떤 폰트로 구웠는지 남긴다. 나중에 "이 편만 글자가 다르다" 를 추적하려면 필요하다.
          "subtitle_font" => font
        },
        file_size: File.stat!(final).size,
        # **섬네일을 물려받는다.**
        #
        # 합성은 부를 때마다 렌더 행을 새로 만든다. 그런데 정상 흐름이
        # 「합성 → check_video → 고침 → 재합성」 이라, 붙여 둔 섬네일이 옛 행에
        # 남고 발행은 최신 행을 본다 — 그래서 올린 영상 22편 전부 섬네일이
        # 없었다(2026-09-29 실측). 파일은 그대로 있으니 경로만 이어 준다.
        thumbnail_path: inherited_thumbnail(project.id)
      }

      with {:ok, render} <- Media.create_render(attrs) do
        {:ok,
         %{
           render_id: render.id,
           file_path: final,
           master_no_subs: master,
           duration_sec: attrs.duration_sec,
           clips: length(pieces),
           subtitles_burned: attrs.burn_subtitles
         }}
      end
    end
  end

  # 나레이션을 장면 길이에 맞춰 저장했으면(tight) 클립 뒤를 잘라 쓴다.
  # 그게 아니면 예전대로 클립을 통째로 쓴다.
  @doc false
  # 이 편에 이미 붙여 둔 섬네일. 파일이 없어졌으면 물려받지 않는다.
  def inherited_thumbnail(project_id) do
    Media.renders(project_id)
    |> Enum.filter(&(&1.kind == "final" and (&1.thumbnail_path || "") != ""))
    |> List.last()
    |> case do
      nil -> ""
      r -> if File.exists?(Path.expand(r.thumbnail_path)), do: r.thumbnail_path, else: ""
    end
  end

  defp fit_mode(narration) do
    if Enum.any?(List.wrap(narration.scene_timing), &(&1["mode"] == "tight")),
      do: :scenes,
      else: :clips
  end

  defp fetch_narration(project) do
    case Media.latest_narration(project.id) do
      nil -> {:error, "나레이션이 없습니다. save_narration 을 먼저 하세요."}
      n -> {:ok, n}
    end
  end

  # 반려한 클립은 후보에서 뺀다. 안 빼면 다시 만든 편에서 **옛 클립이 신뢰도로 이긴다** —
  # 71번은 8개를 새로 만들었는데 3·4·7·8 장면이 구 클립으로 합성됐다 (점검의 "16/8 장면"이 그 신호).
  defp fetch_clips(project) do
    clips =
      project.id
      |> Media.list_assets("clip")
      |> Enum.filter(&(&1.scene_id && &1.status != "rejected" && File.exists?(&1.file_path)))

    if clips == [] do
      {:error, "쓸 수 있는 클립이 없습니다. Flow 결과를 ingest 하세요."}
    else
      {:ok, clips}
    end
  end

  # 장면 순서대로 (클립, 목표 길이) 쌍을 만든다. 클립이 없는 장면은 건너뛴다.
  # 재료가 모자라면 만들지 않는다.
  #
  # 예전에는 장면 16개 중 7개만 클립이 있어도 그 7개로 19초짜리를 만들어 냈다.
  # 나레이션 61.5초 중 42초가 잘려나간 물건이었다 — 그런 건 완성본이 아니라 쓰레기다.
  # 못 만들 상태면 왜 못 만드는지 말하는 게 낫다.
  @min_coverage 0.9
  @min_confidence 0.5

  defp build_plan(clips, narration) do
    timing = narration.scene_timing |> List.wrap()
    total = length(timing)

    # 한 장면에 여러 클립이 오면 가장 확실한 것만 쓴다. 조용히 버리지 않고 세어서 알린다.
    by_scene =
      clips
      |> Enum.group_by(& &1.scene_id)
      |> Map.new(fn {sid, list} -> {sid, Enum.max_by(list, & &1.order_confidence)} end)

    dropped = length(clips) - map_size(by_scene)

    plan =
      Enum.flat_map(timing, fn t ->
        case Map.get(by_scene, t["scene_id"]) do
          nil -> []
          clip -> [%{clip: clip, target: t["target_sec"]}]
        end
      end)

    covered = length(plan)
    best = clips |> Enum.map(& &1.order_confidence) |> Enum.max(fn -> 0.0 end)
    missing = total - covered

    cond do
      plan == [] ->
        {:error, "장면 시간과 클립이 하나도 짝이 안 맞습니다."}

      total > 0 and covered / total < @min_coverage ->
        {:error,
         "클립이 모자랍니다 — 장면 #{total}개 중 #{covered}개만 있습니다 (#{missing}개 빔). " <>
           "이 상태로 만들면 나레이션이 잘려나간 토막 영상이 됩니다. " <>
           "flow_generate(stage: \"video\") 로 나머지를 만들거나 flow_harvest 로 회수하세요." <>
           if(dropped > 0, do: " (같은 장면에 겹친 클립 #{dropped}개는 제외했습니다)", else: "")}

      best < @min_confidence ->
        {:error,
         "클립이 어느 장면 것인지 확신할 수 없습니다 (최고 신뢰도 #{Float.round(best, 2)}). " <>
           "순서가 뒤섞인 영상이 나옵니다. 화면에서 장면 배정을 확인하고 고친 뒤 다시 부르세요."}

      true ->
        {:ok, plan}
    end
  end

  # 기본은 **클립을 그대로 쓴다**. 목표 길이에 맞춰 자르면 8초짜리를 3초로 깎아
  # 만든 영상의 60%를 버리게 된다 — 그럴 거면 만들 이유가 없다.
  # 길이는 결과지 목표가 아니다. 맞추고 싶을 때만 fit: :scenes 를 준다.
  defp retime_all(plan, dir, opts, overlaps) do
    if Keyword.get(opts, :fit, :clips) == :clips do
      {:ok, Enum.map(plan, & &1.clip.file_path)}
    else
      retime_to_scenes(plan, dir, Keyword.get(opts, :aspect, "16:9"), overlaps)
    end
  end

  # 디졸브는 앞 조각을 **그만큼 더 길게** 뽑아 그 몫을 겹쳐 쓴다.
  # 안 그러면 겹친 만큼 영상이 짧아져 나레이션이 뒤로 밀린다.
  defp retime_to_scenes(plan, dir, aspect, overlaps) do
    plan
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {step, i}, {:ok, acc} ->
      out = Path.join([dir, "work", "clip_#{String.pad_leading("#{i}", 2, "0")}.mp4"])
      target = step.target + Enum.at(overlaps, i - 1, 0.0)

      case retime(step.clip.file_path, target, out, aspect) do
        {:ok, path} -> {:cont, {:ok, acc ++ [path]}}
        {:error, r} -> {:halt, {:error, "#{i}번 클립 리타이밍 실패: #{r}"}}
      end
    end)
  end

  # ── 장면 이음매 ───────────────────────────────────────────────
  #
  # 장면이 바뀔 때 툭 끊기는 건 클립 탓이 아니라 **이음매 탓**이다.
  # 다만 모든 이음매가 같지는 않다: 앞 장면의 끝 그림과 다음 장면의 시작 그림이
  # 같은 파일이면(71번의 사슬 구조) 이미 한 호흡으로 이어져 있어 손대면 안 된다.
  # 장소가 바뀌는 이음매에만 0.3초를 겹친다.
  @dissolve_sec 0.3
  # 겹치는 체인을 한 줄로 만들려면 모든 이음매에 겹침이 있어야 한다.
  # 이어진 이음매에는 한 프레임 남짓만 준다 — 같은 그림이라 눈에 안 보인다.
  @seam_sec 0.08

  defp seam_overlaps(project, plan, opts) do
    if Keyword.get(opts, :fit, :clips) == :clips or Keyword.get(opts, :dissolve, true) == false do
      List.duplicate(0.0, length(plan))
    else
      ends = frame_files(project, "info")
      starts = frame_files(project, "clean")

      plan
      |> Enum.chunk_every(2, 1, [nil])
      |> Enum.map(fn
        [_step, nil] ->
          0.0

        [step, next] ->
          want =
            if joined_frame?(ends, starts, step, next), do: @seam_sec, else: @dissolve_sec

          # 앞 조각에 남은 재료 안에서만 겹친다. 없으면 그 이음매는 그냥 컷이다.
          spare = max((step.clip.duration_sec || 0.0) - step.target, 0.0)
          if spare < 0.04, do: 0.0, else: Float.round(min(want, spare), 2)
      end)
    end
  end

  defp frame_files(project, kind) do
    project.id
    |> Media.list_assets(kind)
    |> Enum.filter(&(&1.scene_id && &1.status != "rejected"))
    |> Map.new(&{&1.scene_id, &1.file_path})
  end

  defp joined_frame?(ends, starts, step, next) do
    a = Map.get(ends, step.clip.scene_id)
    b = Map.get(starts, next.clip.scene_id)
    is_binary(a) and a == b
  end

  # 조각들을 하나로 잇는다. 이음매마다 그만큼 겹쳐 디졸브한다.
  # 겹치는 몫은 retime 이 앞 조각에 미리 더해 뒀으므로 전체 길이는 그대로다.
  defp dissolve(pieces, overlaps, dir, opts) do
    cond do
      length(pieces) < 2 -> {:ok, pieces}
      Enum.all?(overlaps, &(&1 <= 0.0)) -> {:ok, pieces}
      true -> stitch(pieces, overlaps, dir, Keyword.get(opts, :aspect, "16:9"))
    end
  end

  @doc """
  이음매마다 `{조각 번호, 겹칠 시간, xfade offset}` 을 낸다.

  offset 은 **지금까지 이어 붙인 길이에서 겹칠 만큼 앞당긴 지점**이다.
  여기를 틀리면 영상이 짧아지고 나레이션이 뒤로 밀린다 — 그래서 따로 떼어 둔다.
  겹침이 0 이면 xfade 가 거부하므로 한 프레임(0.04초)을 최소로 쓴다.
  """
  def seam_plan(durs, overlaps) do
    durs
    |> Enum.with_index()
    |> Enum.drop(1)
    |> Enum.map_reduce(Enum.at(durs, 0, 0.0), fn {d, i}, acc ->
      ov = max(Enum.at(overlaps, i - 1, 0.0), 0.04)
      {{i, ov, max(acc - ov, 0.0)}, acc + d - ov}
    end)
    |> elem(0)
  end

  defp stitch(pieces, overlaps, dir, aspect) do
    out = Path.join([dir, "work", "stitched.mp4"])
    audio? = Enum.all?(pieces, &has_audio?/1)
    durs = Enum.map(pieces, &(probe_sec(&1) || 0.0))

    {filters, vlabel, alabel} =
      durs
      |> seam_plan(overlaps)
      |> Enum.reduce({[], "0:v", "0:a"}, fn {i, ov, offset}, {acc_f, v, a} ->
        nv = "v#{i}"
        na = "a#{i}"

        f =
          ["[#{v}][#{i}:v]xfade=transition=fade:duration=#{f(ov)}:offset=#{f(offset)}[#{nv}]"] ++
            if audio?, do: ["[#{a}][#{i}:a]acrossfade=d=#{f(ov)}[#{na}]"], else: []

        {acc_f ++ f, nv, if(audio?, do: na, else: a)}
      end)

    {w, h} = if aspect == "9:16", do: {1080, 1920}, else: {1920, 1080}

    args =
      ["-v", "error", "-y"] ++
        Enum.flat_map(pieces, &["-i", &1]) ++
        ["-filter_complex", Enum.join(filters, ";"), "-map", "[#{vlabel}]"] ++
        (if audio?, do: ["-map", "[#{alabel}]", "-c:a", "aac", "-b:a", "192k"], else: ["-an"]) ++
        ["-s", "#{w}x#{h}", "-r", "30", "-c:v", "libx264", "-preset", "medium",
         "-crf", "23", "-pix_fmt", "yuv420p", out]

    case done(args, out) do
      {:ok, path} -> {:ok, [path]}
      {:error, r} -> {:error, "이음매 디졸브 실패: #{r}"}
    end
  end

  @doc """
  클립 하나를 목표 길이에 맞춘다 (§5.4).

  f = 목표 / 원본.
    f < 0.85  → 원본이 길다. **앞을 버리고 뒤에서부터** 목표만큼 쓴다 (마지막 프레임이 결론이다)
    0.85~1.35 → 배속으로 맞춘다. 이 정도는 눈에 안 띈다
    f > 1.35  → 원본이 너무 짧다. 1.35배까지만 늘리고 나머지는 마지막 프레임을 정지로 채운다
                (더 늘리면 슬로모션이 티가 난다)
  """
  def retime(src, target, out, aspect) do
    with {:ok, %{duration_sec: source}} <- Ffmpeg.probe(src),
         true <- is_number(source) and source > 0 do
      f = target / source

      cond do
        f < @speed_min -> trim(src, source, target, out, aspect)
        f <= @speed_max -> speed(src, f, out, aspect)
        true -> speed_then_hold(src, source, target, out, aspect)
      end
    else
      _ -> {:error, "원본 길이를 읽지 못했습니다: #{src}"}
    end
  end

  # **앞을 자른다. 뒤가 아니다.**
  # 장면의 마지막 프레임이 INFO 그림 — 라벨·수치가 다 얹힌 그 장면의 결론이다.
  # 뒤를 자르면 장면마다 하려던 말을 끝내기 직전에 끊는다.
  defp trim(src, source, target, out, aspect) do
    start = max(source - target, 0)

    args =
      ["-v", "error", "-y", "-ss", f(start), "-i", src, "-t", f(target)] ++
        enc(aspect) ++ audio_args(src, nil) ++ [out]

    done(args, out)
  end

  # 리타이밍한 조각도 소리를 갖고 가야 한다. -an 으로 지우면 Flow 가 만든 배경음이
  # 통째로 사라진다 (실측: 합성본에 나레이션만 남았다).
  defp audio_args(src, af) do
    if has_audio?(src) do
      if(af, do: ["-filter:a", af], else: []) ++ ["-c:a", "aac", "-b:a", "192k"]
    else
      ["-an"]
    end
  end

  defp speed(src, factor, out, aspect) do
    args =
      ["-v", "error", "-y", "-i", src] ++
        enc(aspect, "setpts=#{f(factor)}*PTS") ++
        audio_args(src, "atempo=#{f(1 / factor)}") ++ [out]

    done(args, out)
  end

  # 최대 배속까지 늘린 뒤 남는 시간은 마지막 프레임을 정지로 붙인다.
  defp speed_then_hold(src, source, target, out, aspect) do
    stretched = source * @speed_max
    hold = max(target - stretched, 0)

    chain =
      "setpts=#{f(@speed_max)}*PTS," <>
        "tpad=stop_mode=clone:stop_duration=#{f(hold)}"

    # apad 는 -t 와 짝이다. -t 없이 쓰면 출력이 끝나지 않는다 (실측: 9분간 파일이 자랐다).
    args =
      ["-v", "error", "-y", "-i", src] ++
        enc(aspect, chain) ++
        audio_args(src, "atempo=#{f(1 / @speed_max)},apad") ++ ["-t", f(target), out]

    done(args, out)
  end

  # 이어 붙일 조각들은 코덱·해상도·fps 가 같아야 concat 이 깨지지 않는다.
  #
  # 해상도를 1920x1080 으로 박아두면 **세로 클립이 가로 판에 끼워져** 좌우가 검게 되고
  # 자막도 그 넓은 판 기준으로 얹힌다 — 실측: 720x1280 클립이 1920x1080 으로 나왔다.
  # 화면비를 받아서 판을 정한다.
  defp enc(aspect), do: enc(aspect, nil)

  # 앞에 붙일 필터(setpts, tpad …)는 여기로 넘긴다. `-filter:v` 로 따로 주면
  # enc 의 `-vf` 가 덮어써서 배속이 조용히 사라진다 — 같은 옵션이기 때문이다.
  defp enc(aspect, pre) do
    {w, h} = if aspect == "9:16", do: {1080, 1920}, else: {1920, 1080}

    chain =
      [pre, "scale=#{w}:#{h}:force_original_aspect_ratio=decrease",
       "pad=#{w}:#{h}:(ow-iw)/2:(oh-ih)/2:black", "setsar=1"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(",")

    [
      "-r", "30",
      "-vf", chain,
      "-c:v", "libx264",
      "-preset", "medium",
      "-crf", "23",
      "-pix_fmt", "yuv420p"
    ]
  end

  defp done(args, out) do
    case Ffmpeg.exec(args) do
      {:ok, _} -> if File.exists?(out), do: {:ok, out}, else: {:error, "출력 파일이 없습니다"}
      {:error, r} -> {:error, r}
    end
  end

  defp concat_and_mix(pieces, narration, dir) do
    list = Path.join([dir, "work", "concat.txt"])
    # concat demuxer 는 작은따옴표를 이스케이프해야 한다. 경로는 절대경로로 준다.
    body = Enum.map_join(pieces, "\n", fn p -> "file '#{String.replace(p, "'", "'\\''")}'" end)
    File.write!(list, body <> "\n")

    out = Path.join(dir, "master_nosub.mp4")

    # 소리는 세 겹이다: 클립 효과음 · 배경 음악 · 나레이션.
    # Flow 에는 효과음만 만들게 한다 (대사도 음악도 넣지 말라고 상시 지시에 박아 뒀다).
    # 음악은 여기서 깐다 — work/bgm.* 가 있으면 쓰고, 없으면 그냥 두 겹으로 간다.
    sfx? = has_audio?(List.first(pieces))
    bgm = find_bgm(dir)

    # 무한 반복하는 입력(-stream_loop) 과 apad 가 섞이면 끝나는 지점이 사라진다.
    # 그래서 길이를 여기서 못 박는다 — 조각 길이의 합이 곧 영상 길이다.
    total = Enum.reduce(pieces, 0.0, fn p, acc -> acc + (probe_sec(p) || 0.0) end)

    inputs =
      ["-f", "concat", "-safe", "0", "-i", list, "-i", narration.file_path] ++
        if bgm, do: ["-stream_loop", "-1", "-i", bgm], else: []

    audio =
      if sfx? or bgm do
        ["-filter_complex", audio_filter(sfx?, not is_nil(bgm)), "-map", "[a]"]
      else
        # 소리 없는 클립에 음악도 없다 — 나레이션만 싣고 뒤는 무음으로 채운다.
        ["-map", "1:a:0", "-af", "apad"]
      end

    args =
      ["-v", "error", "-y"] ++
        inputs ++
        ["-map", "0:v:0"] ++
        audio ++
        [
          "-c:v", "copy",
          "-c:a", "aac", "-b:a", "192k",
          "-t", f(total),
          out
        ]

    done(args, out)
  end

  @doc false
  # 소리 세 겹(클립 효과음 · 배경 음악 · 나레이션)을 하나로 섞는 필터.
  # 나레이션이 위, 효과음은 -12dB, 음악은 -23dB. 레벨은 **고정이다.**
  #
  # **dynaudnorm 을 다시 끼우지 마라.** 15초짜리 창으로 이득을 계속 다시 잡아서
  # 앞부분이 조용하다가 중간에 소리가 확 커진다 — 58편 실측으로 0초 -27.0 LUFS 에서
  # 16초 -15.8 LUFS 까지 11dB 올라갔다. 나레이션 파일 자체는 평평했고 합성본만 출렁였다.
  # amix 도 normalize=0 이어야 한다. 기본값(1) 은 입력 수로 나눠서 소리를 죽이고,
  # 그걸 메우려고 자동 정규화를 붙이면 위 문제가 그대로 돌아온다.
  # 지금 값: -20.3 LUFS · LRA 2.1 · 피크 -1.5 dBFS.
  def audio_filter(sfx?, bgm?) do
    layers =
      (if sfx?, do: ["[0:a]volume=0.35[sfx]"], else: []) ++
        (if bgm?, do: ["[2:a]volume=0.14[bgm]"], else: []) ++
        ["[1:a]volume=1.4,apad[nar]"]

    mixed = (if sfx?, do: ["[sfx]"], else: []) ++ (if bgm?, do: ["[bgm]"], else: []) ++ ["[nar]"]

    Enum.join(layers, ";") <>
      ";" <>
      Enum.join(mixed) <>
      "amix=inputs=#{length(mixed)}:duration=longest:dropout_transition=0:normalize=0," <>
      "alimiter=limit=0.95[a]"
  end

  @doc """
  이 프로젝트에 깔 배경 음악. `work/bgm.mp3`(또는 wav·m4a·ogg) 를 두면 쓴다.

  서버가 음악을 만들지는 않는다 — 힉스필드의 음악 모델은 게임 파이프라인 전용이라
  막혀 있다. 무료 음원을 받아 저 경로에 두는 것이 지금 방식이다.
  """
  def find_bgm(dir) do
    ~w(mp3 wav m4a ogg)
    |> Enum.map(&Path.join([dir, "work", "bgm.#{&1}"]))
    |> Enum.find(&File.exists?/1)
  end

  defp probe_sec(path) do
    case Ffmpeg.probe(path) do
      {:ok, %{duration_sec: d}} when is_number(d) -> d
      _ -> nil
    end
  end

  defp has_audio?(nil), do: false

  defp has_audio?(path) do
    case System.cmd("ffprobe", ["-v", "error", "-select_streams", "a", "-show_entries",
                                "stream=index", "-of", "csv=p=0", path], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  rescue
    _ -> false
  end

  # 자막 하드번. 실패해도 마스터는 남기고 진행한다 — 자막 때문에 완성본을 통째로 잃지 않는다.
  defp burn_subtitles(project, master, narration, dir, opts) do
    if Keyword.get(opts, :burn, true) do
      font = Keyword.get(opts, :font) || VideoTool.Presets.default_subtitle_font()

      case write_ass(project, narration, dir, font, Keyword.get(opts, :aspect, "16:9")) do
        {:ok, ass} -> try_burn(master, ass, dir)
        {:error, r} ->
          Logger.warning("자막 파일 생성 실패, 자막 없이 진행: #{r}")
          {:ok, master}
      end
    else
      {:ok, master}
    end
  end

  defp try_burn(master, ass, dir) do
    out = Path.join(dir, "final.mp4")

    # Windows 는 subtitles 필터에 드라이브 콜론이 들어가면 깨진다.
    # 작업 폴더로 들어가 파일 이름만 준다.
    # 자막 굽기는 System.cmd 로 직접 부르므로 Ffmpeg.exec 의 스레드 제한을 못 받는다.
    # 여기서 안 막으면 인코딩이 코어를 전부 먹고 서버가 응답을 멈춘다 (2026-09-21).
    threads = to_string(max(div(System.schedulers_online(), 2), 2))

    args = [
      "-v", "error", "-y",
      "-threads", threads,
      "-i", master,
      "-vf", "subtitles=#{Path.basename(ass)}",
      "-c:a", "copy",
      "-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p",
      out
    ]

    case System.cmd("ffmpeg", args, cd: dir, stderr_to_stdout: true) do
      {_, 0} ->
        if File.exists?(out), do: {:ok, out}, else: {:ok, master}

      {log, _} ->
        Logger.warning("자막 하드번 실패, 자막 없는 마스터로 진행: #{String.slice(log, 0, 300)}")
        {:ok, master}
    end
  end

  defp write_ass(project, narration, dir, font, aspect) do
    rows = Media.subtitles(narration.id)

    if rows == [] do
      {:error, "자막 줄이 없습니다"}
    else
      body =
        (Enum.map(rows, &ass_line/1) ++ label_lines(project, narration))
        |> Enum.join("\n")

      path = Path.join(dir, "subs.ass")
      File.write!(path, ass_header(font, aspect) <> body <> "\n")
      {:ok, path}
    end
  end

  # 장면마다 짧은 설명 글자를 **화면 위쪽**에 얹는다 (`scene.expected_labels`).
  # 자막은 아래(MarginV 260)에 있어 겹치지 않는다.
  # 그림에 글자를 그려 달라고 하지 않는 이유: 생성기는 한글을 못 쓴다 — 글자 모양만 흉내 낸
  # 것이 나오고, INFO 프롬프트도 "글자 절대 금지" 로 잡혀 있다. 여기서 구우면 정확하다.
  defp label_lines(project, narration) do
    timing = Map.new(narration.scene_timing || [], &{&1["scene_id"], &1})

    project.id
    |> Projects.scenes()
    |> Enum.flat_map(fn scene ->
      with %{"start" => from0, "end" => stop} <- Map.get(timing, scene.id),
           [_ | _] = labels <- scene.expected_labels do
        # **하나만 올린다.** 96pt 로 키운 뒤 두 개를 `·` 로 붙이면 폭 1080 을 넘겨
        # 줄이 바뀌고, 숫자와 단위가 갈리면서 수치가 죽는다(2026-09-22 교훈).
        # 여러 개를 보여줘야 하면 장면을 나누는 게 맞다.
        text = labels |> Enum.take(1) |> Enum.join()
        from = from0 + 0.3
        # 장면이 5.5초로 짧아졌다. 3.2초를 붙들면 장면 내내 떠 있는 꼴이 된다.
        to = min(from + 2.4, stop - 0.25)

        # 스치듯 지나가면 읽히지 않는다. 0.8초를 못 채우면 아예 안 넣는다.
        if to - from >= 0.8,
          do: ["Dialogue: 1,#{ts(from)},#{ts(to)},Label,,0,0,0,,{\\fad(250,250)}#{escape(text)}"],
          else: []
      else
        _ -> []
      end
    end)
  end

  # 자막 판을 화면비에 맞춘다. 1920x1080 으로 고정해 두면 9:16 영상에서 글자가
  # 가로로 눌려 나오고, 한 줄이 화면 밖으로 넘친다 — 세로는 폭이 절반도 안 된다.
  # 자막을 화면 어디에 두는가. ASS 정렬은 숫자판 배치다 — 2 는 아래 가운데, 5 는 한가운데.
  # 가운데로 올리면 그림을 가리므로, 그림이 아까우면 2 로 되돌린다.
  @sub_align 5
  # 외곽선을 두껍게. 배경이 밝은 그림체(로우폴리·플랫)에서 흰 글자가 묻히던 것을 막는다.
  @sub_outline 4
  @sub_shadow 0

  defp ass_header(font, aspect) do
    {w, h, size, margin_x, margin_v, label_size, label_v} =
      case aspect do
        # 세로는 폭이 1080 뿐이다. 글자를 키우면 두세 글자마다 줄이 바뀐다.
        #
        # 2026-09-23 요청으로 둘 다 키웠다:
        #   아래 자막(size)      52 → 68  (1.3배). 한 줄 13~15자 → 10~11자로 줄어
        #                        두 줄이 세 줄이 되기 쉽다. 그래서 좌우 여백을 80 → 60 으로
        #                        줄여 폭을 벌고, 아래 여백도 260 → 210 으로 내렸다.
        #   위쪽 라벨(label_size) 58 → 96. 대신 **핵심 단어 하나만** 올린다(label_lines 참고)
        # 2026-09-29 요청: 자막을 키우고 **화면 가운데**로 올렸다 (Alignment 5).
        #   자막(size) 68 → 84. 대신 한 줄을 18자로 끊는다(@sub_max_chars) — 안 그러면 세 줄이 된다.
        #   가운데 정렬이라 MarginV 는 0 이다. 아래쪽으로 내리려면 @sub_align 을 2 로 되돌린다.
        "9:16" -> {1080, 1920, 84, 60, 0, 96, 170}
        _ -> {1920, 1080, 82, 120, 0, 84, 80}
      end

    """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: #{w}
    PlayResY: #{h}
    WrapStyle: 0
    ScaledBorderAndShadow: yes

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BackColour, Bold, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    ; Label 은 2026-09-23 요청으로 외곽선·그림자를 뺐다(Outline 0, Shadow 0)
    ; 색은 흰색(&H00FFFFFF). 우리 화면은 어두운 스튜디오라 흰 글자가 읽힌다 —
    ; 밝은 배경 그림체로 바꾸면 이 줄을 검은색(&H00000000)으로 되돌려야 한다.
    Style: Default,#{font},#{size},&H00FFFFFF,&H00000000,&H80000000,1,1,#{@sub_outline},#{@sub_shadow},#{@sub_align},#{margin_x},#{margin_x},#{margin_v},1
    Style: Label,#{font},#{label_size},&H00FFFFFF,&H00000000,&H00000000,1,1,0,0,8,#{margin_x},#{margin_x},#{label_v},1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """
  end

  defp ass_line(row) do
    "Dialogue: 0,#{ts(row.start_sec)},#{ts(row.end_sec)},Default,,0,0,0,,#{escape(row.text)}"
  end

  # ASS 는 h:mm:ss.cc (1/100초)
  defp ts(sec) do
    total = max(sec, 0)
    h = trunc(total / 3600)
    m = trunc(rem(trunc(total), 3600) / 60)
    s = :erlang.float_to_binary(total - h * 3600 - m * 60, decimals: 2)
    s = if String.length(s) < 5, do: "0" <> s, else: s
    "#{h}:#{String.pad_leading("#{m}", 2, "0")}:#{s}"
  end

  defp escape(text) do
    text
    |> String.replace("\n", "\\N")
    |> String.replace("{", "\\{")
    |> String.replace("}", "\\}")
  end

  defp f(num), do: :erlang.float_to_binary(num / 1, decimals: 4)

  defp work_dir(project) do
    case project.work_dir do
      nil -> Path.join(["projects", "#{project.id}"])
      "" -> Path.join(["projects", "#{project.id}"])
      dir -> dir
    end
  end
end
