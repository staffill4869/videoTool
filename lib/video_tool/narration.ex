defmodule VideoTool.Narration do
  @moduledoc """
  나레이션을 일레븐랩스로 직접 만든다 — 장면별 음성 → 장면 길이 맞춤 → 이어 붙여 등록.

  예전엔 에이전트가 힉스필드 TTS 에 문장을 **손으로 옮겨** 보냈다. 그러다 "얕은 잠" 이
  "약은 잠", "푹" 이 "푺" 으로 들어갔고(61·65번), 힉스필드 쪽은 8.00초에서 말을 잘랐다.
  여기서는 DB 의 대본 구간을 그대로 보낸다. 옮겨 적는 단계가 없다.

  장면 음성 길이 규칙은 수동으로 하던 것과 같다: 뒤에 0.3초 여유, 여유를 붙여도 7.95초까지만.
  말 자체가 그보다 길면 자르지 않는다(말이 잘린다) — 그 장면은 길게 남고, 대본을 줄여서 푼다.
  마지막 장면은 여유 없이 그대로 (합성이 마지막 클립을 통째로 쓴다).
  파일은 `work/tts/sNN.mp3` — `Assembly` 가 이 이름으로 장면 시간을 잰다.
  """

  alias VideoTool.{Assembly, Ffmpeg, Projects, Settings}

  @url "https://api.elevenlabs.io/v1/text-to-speech"
  @model "eleven_multilingual_v2"
  @gap 0.3
  @cap 7.95

  @doc "opts: voice_id (없으면 project.variables[\"eleven_voice_id\"]), model_id, language (기본 ko)"
  def generate(project, opts \\ []) do
    # **목소리는 시리즈에 박힌 것이 먼저다.** opts 를 앞에 두면 에이전트가 넣는 값이
    # 매번 이긴다 — 실측(2026-09-30, 2시간 로그): 한 채널 안에서 영어 목소리 Adam 3회,
    # 힉스필드 UUID 2회가 섞여 편마다 목소리가 달랐고, 한국어 대본을 영어 목소리로
    # 읽은 편이 그대로 발행됐다.
    voice =
      pinned_voice(project) ||
        get_in(project.variables || %{}, ["eleven_voice_id"]) ||
        opts[:voice_id]
    key = Settings.get(:elevenlabs_api_key)
    lang = opts[:language] || project.language || "ko"

    with :ok <- need(key, "ELEVENLABS_API_KEY 가 없습니다. .env 에 넣고 서버를 다시 켜세요."),
         :ok <- need(voice, "voice_id 가 없습니다. 일레븐랩스 목소리 id 를 주세요."),
         {:ok, lines} <- lines(project) do
      dir = Path.join([project.work_dir, "work", "tts"])
      File.mkdir_p!(dir)
      last = length(lines)

      results =
        Enum.map(lines, fn {no, text} ->
          raw = Path.join(dir, "raw#{no}.mp3")
          out = Path.join(dir, "s#{String.pad_leading("#{no}", 2, "0")}.mp3")

          with {:ok, _} <- speak(key, voice, text, lang, opts[:model_id] || @model, raw),
               {:ok, spoken} <- Ffmpeg.duration(raw),
               target = if(no == last, do: spoken, else: min(spoken + @gap, @cap)),
               {:ok, _} <- pad(raw, target, out) do
            # apad 는 늘리기만 한다. 말이 상한보다 길면 파일도 그만큼 길다 — 실제 길이를 보고해야
            # "7.95초" 로 믿고 넘어가지 않는다 (67번: 보고 7.95, 실제 8.54). 줄일 땐 대본을 고친다.
            {:ok, %{scene_no: no, spoken: spoken, seconds: max(spoken, target)}}
          end
        end)

      case Enum.find(results, &match?({:error, _}, &1)) do
        nil ->
          files = Enum.map(lines, fn {no, _} -> Path.join(dir, "s#{String.pad_leading("#{no}", 2, "0")}.mp3") end)
          joined = Path.join([project.work_dir, "work", "narration_eleven.mp3"])

          with {:ok, _} <- concat(files, joined, dir),
               {:ok, saved} <- Assembly.save_narration(project, joined, scene_secs: nil) do
            {:ok, Map.put(saved, :scenes_tts, Enum.map(results, fn {:ok, r} -> r end))}
          end

        err ->
          err
      end
    end
  end

  # 프로젝트에 붙은 목소리(시리즈에서 물려받는다)의 일레븐랩스 id.
  # `voices.voice_id` 는 힉스필드 UUID 라 나레이션에 못 쓴다 — 그래서 칸을 따로 뒀다.
  defp pinned_voice(%{voice_id: id}) when not is_nil(id) do
    case VideoTool.Repo.get(VideoTool.Presets.Voice, id) do
      %{eleven_voice_id: v} when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp pinned_voice(_), do: nil

  defp need(v, _msg) when is_binary(v) and v != "", do: :ok
  defp need(_, msg), do: {:error, msg}

  # 장면 번호 순서대로 (번호, 대본 구간). 구간이 빈 장면이 있으면 멈춘다 — 조용히 건너뛰면
  # 그 장면만 무음이 되고 뒤 장면이 전부 한 칸씩 당겨진다.
  defp lines(project) do
    script = Projects.active_script(project.id)
    segs = Projects.segments_by_scene(script && script.id)

    pairs =
      project.id
      |> Projects.scenes()
      |> Enum.map(&{&1.scene_no, String.trim(segs[&1.id] || "")})

    case Enum.find(pairs, fn {_, t} -> t == "" end) do
      nil when pairs != [] -> {:ok, pairs}
      nil -> {:error, "장면이 없습니다."}
      {no, _} -> {:error, "#{no}번 장면에 대본 구간이 없습니다. save_scenes 로 segment_text 를 넣으세요."}
    end
  end

  defp speak(key, voice, text, lang, model, out) do
    case Req.post("#{@url}/#{voice}",
           params: [output_format: "mp3_44100_128"],
           headers: [{"xi-api-key", key}],
           json: %{text: text, model_id: model, language_code: lang},
           receive_timeout: 120_000,
           retry: :transient
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        File.write!(out, body)
        {:ok, out}

      {:ok, %{status: status, body: body}} ->
        {:error, "일레븐랩스 #{status}: #{inspect(body) |> String.slice(0, 300)}"}

      {:error, e} ->
        {:error, "일레븐랩스 호출 실패: #{Exception.message(e)}"}
    end
  end

  defp pad(raw, seconds, out) do
    Ffmpeg.exec(["-v", "error", "-y", "-i", raw, "-af", "apad=whole_dur=#{seconds}",
                 "-c:a", "libmp3lame", "-q:a", "2", out])
  end

  defp concat(files, out, dir) do
    list = Path.join(dir, "list.txt")
    File.write!(list, Enum.map_join(files, "\n", &"file '#{String.replace(&1, "\\", "/")}'"))
    Ffmpeg.exec(["-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", list,
                 "-c:a", "libmp3lame", "-q:a", "2", out])
  end
end
