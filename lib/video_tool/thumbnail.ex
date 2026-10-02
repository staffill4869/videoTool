defmodule VideoTool.Thumbnail do
  @moduledoc """
  섬네일 지시문을 만들어 주고, 만들어진 이미지를 완성본에 붙인다.

  서버는 이미지를 만들지 못한다 (생성 키가 없다). 그래서 여기서 하는 일은 둘뿐이다 —
  **무엇을 그릴지 글로 내주고**, 받아 온 파일을 `renders.thumbnail_path` 에 꽂는다.
  발행할 때 `youtube/upload.ex` 가 그 경로를 그대로 올린다.

  지시문을 코드에 둔 이유: 섬네일 규칙이 매번 말로 전달되다 보니 편마다 달라졌다.
  제목에 「영양제, 왜 그런가 #1」 같은 프로젝트 이름이 그대로 박힌 편이 있었다.
  """

  alias VideoTool.{Media, Projects, Series}

  # 유튜브가 요구하는 규격. 세로 영상이어도 커스텀 섬네일은 16:9 다.
  @size "1280x720"

  @common """
  ## 절대 규칙 — 여기서 틀리면 다시 만든다

  - **가로 #{@size} (16:9).** 세로로 만들지 마라. 영상이 세로여도 섬네일은 가로다
  - **프로젝트 이름·시리즈 이름·회차 번호 금지.** "고양이는 왜 그럴까 #5" 같은 관리용
    제목을 구석에 박지 마라. 시청자에게 아무 의미가 없고 자리만 먹는다
  - **문장을 쓰지 마라.** 글자 덩어리는 최대 3개, 각각 2~6글자. 마침표 금지.
    좋은 예: "시공 직후" / "6개월 후" / "완전 막힘"
    나쁜 예: "골골거리면 기분 좋은 거라고? 다쳤을 때도 골골거립니다"
  - **글자를 아주 크게.** 한 덩어리가 화면 가로폭의 3분의 1은 되어야 한다.
    폰에서 엄지손톱만 하게 보여도 읽혀야 한다
  - 글자는 굵은 고딕, 흰색에 **두꺼운 검은 테두리**. 강조할 한 덩어리만 노란색
  - 글자는 **모서리·가장자리에** 붙인다. 가운데는 그림이 말하는 자리다
  - 그림 안에 다른 글자(라벨·숫자·로고·워터마크)는 넣지 마라
  - 영상 본편의 그림체를 따른다. 딴 화풍이면 눌러 놓고 다른 영상이 열린 느낌이 난다
  """

  @split """
  ## 구성 — 좌우로 갈라 비교한다

  화면을 **세로선 하나로 반 갈라** 같은 것을 두 번 보여 준다. 이게 뼈대다.
  누르기 전에 "어? 왜 저렇게 달라지지" 가 보여야 한다.

  - 왼쪽과 오른쪽에 **대비되는 두 상태**를 놓는다
  - **같은 대상, 같은 각도, 같은 거리.** 달라지는 건 이번 편이 설명하는 그 한 가지뿐이다.
    대상이 바뀌면 비교가 아니라 그냥 다른 그림 두 장이다
  - 가운데 경계선은 얇고 선명하게
  - 왼쪽은 가라앉은 색, 오른쪽은 밝은 색 — 차이를 색으로도 만든다
  - **각 칸 위쪽에 라벨 하나씩**, 2~6글자로 아주 크게 (예: "먹기 전" / "먹은 후")
  - 결론 한 덩어리를 아래 한쪽 구석에 노란색으로 (예: "완전 막힘")
  - "BEFORE / AFTER" 같은 영어는 쓰지 마라
  """

  @doc """
  이 프로젝트의 섬네일 지시문. 코워크·에이전트가 그대로 읽고 그리면 된다.
  """
  def brief(project) do
    """
    # 섬네일 지시문 — #{project.title}

    이 영상의 내용: #{summary(project)}

    #{@split}
    #{@common}

    ## 두 칸에 무엇을 놓을까

    이 편이 뒤집는 **통념과 사실**을 좌우로 놓는다. 없으면 **변화의 전/후**를 놓는다.
    #{hint(project)}

    라벨 두 개와 결론 한 덩어리, 합쳐서 세 덩어리를 넘기지 마라.
    다 만들었으면 save_thumbnail(project_id, file) 로 넘긴다.
    """
  end

  # 시리즈마다 "두 칸" 이 자연스럽게 잡히는 축이 다르다. 그걸 예시로 하나 준다 —
  # 백지에서 고르라고 하면 매번 다른 구성이 나와 시리즈가 따로 논다.
  defp hint(project) do
    series = series_of(project)
    text = "#{series && series.name} #{project.title} #{project.topic}"

    cond do
      String.contains?(text, ["영양제", "비타민", "유산균", "마그네슘", "철분"]) ->
        ~s(예: "빈속에" / "밥이랑" · "먹기 전" / "먹은 후")

      String.contains?(text, ["고양이", "모모"]) ->
        ~s(예: "기분 좋을 때" / "아플 때" · "이럴 거라 생각" / "사실은")

      true ->
        ~s(예: "그때" / "지금" · "알려진 이유" / "진짜 이유")
    end
  end

  @doc """
  본편 그림으로 섬네일을 **직접 만든다.** 1번 장면의 INFO 이미지 위에
  검은 띠를 깔고 큰 글자 두 줄을 얹는다.

  따로 그리지 않는 이유: 그리면 편당 비용이 들고 그림체가 본편과 어긋난다.
  이미 만든 그림을 쓰면 값이 0 이고 화풍이 100% 같다.

  띠를 까는 이유: 그림 위에 바로 글자를 얹으면 배경색과 붙어 안 읽힌다.
  로우폴리·플랫 화풍은 배경이 밝아서 흰 글자가 특히 묻힌다.

  **글자는 ASS 로 굽는다.** 서버 ffmpeg 빌드에 drawtext 가 없다 —
  자막을 굽는 것과 같은 경로라 한글이 안 깨진다.
  """
  @w 1280
  @h 720
  # **쓰는 곳보다 위에 둔다.** 아래에 뒀더니 compose_vertical 에서 nil 이 되어
  # `1920 - nil` 로 터졌다 (실측 2026-10-02). 모듈 속성은 정의 시점 이후에만 값이 있다.
  #
  # @band_top  : 띠를 화면 맨 위에 붙이지 않고 조금 내린다.
  # @img_shift : 세로판에서 그림을 아래로 미는 양. 머리가 띠에 잘리던 것을 막는다.
  @band_top 130
  @img_shift 290

  # **둘째 줄 색은 편마다 바꾼다.** 같은 노랑이 계속 나오면 채널이 단조로워 보인다.
  # 무작위가 아니라 **프로젝트 번호 기준**이다 — 다시 만들어도 같은 색이 나와야
  # "아까 그 섬네일" 을 찾을 수 있다.
  # ASS 색은 &HBBGGRR& 순서다 (RGB 가 아니다). 전부 어두운 띠 위에서 읽히는 밝은 색이다.
  @accents [
    "&H0055E7FF&",
    "&H0066FF66&",
    "&H00FF9955&",
    "&H00FF77DD&",
    "&H0066DDFF&",
    "&H00AAFF00&"
  ]

  def compose(project, line1, line2 \\ "") do
    {_, band} = layout(@w, @h, [line1, line2])
    out = Path.join(work_dir(project), "thumb.jpg")

    with {:ok, src} <- hero_image(project) do
      ass = write_ass(project, line1, line2, @w, @h, "thumb.ass")

      # **띠를 덧대지 말고 그림 위에 얹는다.**
      #
      # 예전에는 그림을 (720 - 띠) 칸에 꽉 채우고 검은 띠를 `pad` 로 아래에 덧댔다.
      # 9:16 원본을 1280x460 에 채우려면 세로의 20%만 남는다 —
      # 실측: 768x1376 을 폭 1280 에 맞추면 높이가 2293 이 되고 그중 460 만 쓴다.
      # 잔이 화면을 꽉 채우는 확대 사진이 돼 장면이 뭔지 알 수 없었다.
      #
      # 720 전체에 채우고 띠를 `drawbox` 로 위에 그리면 31% 가 남아 장면이 보인다.
      # 띠가 가리는 위쪽은 대개 배경이라 잃는 것이 적다.
      # (drawtext 는 이 빌드에 없지만 drawbox 는 폰트가 필요 없어 쓸 수 있다.)
      args = [
        "-v", "error", "-y", "-i", src,
        "-vf",
        content_crop(src) <>
          # **가로판은 얼굴이 띠 바로 밑에 오게 자른다.** 세로 원본(9:16)을 16:9 로 자르면
          # 가운데만 남아 다리만 나왔고, 0.26 으로 내렸더니 이번엔 목 아래 몸통만 나왔다
          # (둘 다 실측 2026-10-02). 얼굴은 세로 원본 위쪽 13% 쯤에 있고 띠는 720 의 112 이니
          # 폭 1280 으로 키운 높이(2276)의 5% 지점에서 자르면 얼굴이 띠 아래 180 쯤에 앉는다.
          "scale=#{@w}:#{@h}:force_original_aspect_ratio=increase," <>
          "crop=#{@w}:#{@h}:(iw-#{@w})/2:ih*0.05," <>
          "drawbox=x=0:y=0:w=#{@w}:h=#{band}:color=black:t=fill," <>
          "subtitles=#{Path.basename(ass)}",
        "-frames:v", "1", "-pix_fmt", "yuvj420p", "-q:v", "2", Path.basename(out)
      ]

      case System.cmd("ffmpeg", args, cd: Path.dirname(ass), stderr_to_stdout: true) do
        {_, 0} ->
          # 쇼츠 세로 타일용 짝을 같이 만들어 둔다. 실패해도 그냥 넘어간다 —
          # 가로판은 자동으로 올라가고, 세로판은 손으로 올리는 보조 파일이다.
          _ = compose_vertical(project, line1, line2, src)

          if File.exists?(out), do: {:ok, out}, else: {:error, "섬네일 파일이 없습니다"}

        {log, _} -> {:error, "섬네일 합성 실패: #{String.slice(log, 0, 200)}"}
      end
    end
  end

  @vw 1080
  @vh 1920

  @doc """
  쇼츠 세로 타일(9:16)용 짝. **유튜브 API 로는 이 자리를 못 쓴다.**

  실측(2026-09-30): 1080x1920 을 `thumbnails.set` 으로 올리면 유튜브가 좌우를 흐리게
  채운 16:9 로 바꿔 16:9 슬롯에 넣을 뿐이고, 쇼츠 타일(`oar2`)은 그대로 영상 프레임이다.
  두 편으로 각각 확인했고 6분을 기다려도 같았다.

  그래서 이 파일은 **올리는 용도가 아니라 넘기는 용도**다 — 화면에서 받아
  유튜브 스튜디오의 쇼츠 섬네일 칸에 끌어다 놓으면 된다.
  """
  def compose_vertical(project, line1, line2, src) do
    # 띠는 **글자가 차지하는 만큼만, 최대 높이의 2.5/16** (layout/3). 620 으로 고정했더니
    # 띠가 화면의 32% 를 먹어 얼굴을 덮었다.
    {_, band} = layout(@vw, @vh, [line1, line2])
    out = Path.join(work_dir(project), "thumb916.jpg")
    ass = write_ass(project, line1, line2, @vw, @vh, "thumb916.ass")

    args = [
      "-v", "error", "-y", "-i", src,
      "-vf",
      content_crop(src) <>
        # **그림을 아래로 밀어 머리가 띠에 안 잘리게 한다.**
        # 세로 원본은 얼굴이 위쪽 13% 쯤에 있어 띠(15%)가 그대로 덮었다 (실측 2026-10-02).
        # 위를 @img_shift 만큼 잘라내고 그만큼 아래에 덧대면 인물이 통째로 내려온다 —
        # 덧댄 자리는 어차피 띠가 덮는다.
        "scale=#{@vw}:#{@vh}:force_original_aspect_ratio=increase,crop=#{@vw}:#{@vh}," <>
        "crop=#{@vw}:#{@vh - @img_shift}:0:0,pad=#{@vw}:#{@vh}:0:#{@img_shift}:black," <>
        "drawbox=x=0:y=#{@band_top}:w=#{@vw}:h=#{band}:color=black:t=fill," <>
        "subtitles=#{Path.basename(ass)}",
      "-frames:v", "1", "-pix_fmt", "yuvj420p", "-q:v", "2", Path.basename(out)
    ]

    case System.cmd("ffmpeg", args, cd: Path.dirname(ass), stderr_to_stdout: true) do
      {_, 0} -> if File.exists?(out), do: {:ok, out}, else: {:error, "세로판이 없습니다"}
      {log, _} -> {:error, "세로판 합성 실패: #{String.slice(log, 0, 200)}"}
    end
  end

  # **원본에 붙은 검은 띠를 먼저 잘라낸다.**
  # Flow 가 돌려준 그림 일부는 아래 19% 가 검은 띠다 (실측 2026-10-01: 36편 중 4편).
  # 그대로 키우면 섬네일 아래가 통째로 검게 비어 손으로 올릴 수가 없다.
  # `scale=...:increase` 는 비율만 맞출 뿐 띠를 못 본다 — 띠까지 '그림' 으로 치기 때문이다.
  # 흰 띠는 못 잡는다 (cropdetect 는 어두운 쪽만 본다). 흰 띠가 나오면 그때 다시 본다.
  defp content_crop(src) do
    # `-loop 1 -frames:v 4`: 정지 그림 한 장만 넣으면 cropdetect 가 아무것도 안 찍는다.
    # limit 40: 실측한 띠는 순검정이 아니라 **짙은 남색**(luma 약 34)이라 기본값 24 로는 안 잡혔다.
    # 멀쩡한 편(126)에 같은 40 을 걸어도 1376 그대로 — 진짜 그림은 안 깎인다.
    args = ["-loop", "1", "-i", src, "-vf", "cropdetect=40:2:0", "-frames:v", "4", "-f", "null", "-"]

    with {log, _} <- System.cmd("ffmpeg", args, stderr_to_stdout: true),
         [_, crop, w, h] <- Regex.run(~r/(crop=(\d+):(\d+):\d+:\d+)/, log),
         {:ok, %{width: ow, height: oh}} <- VideoTool.Ffmpeg.probe(src),
         true <- ow > 0 and oh > 0,
         # 너무 많이 깎으면 띠가 아니라 어두운 장면이다. 6할은 남겨야 믿는다.
         true <- String.to_integer(w) * String.to_integer(h) >= div(ow * oh * 6, 10) do
      crop <> ","
    else
      _ -> ""
    end
  end

  # 1번 장면의 INFO. 없으면 CLEAN. 훅 장면이라 이 편이 무슨 이야기인지 한눈에 보인다.
  defp hero_image(project) do
    scene = project.id |> Projects.scenes() |> List.first()

    if is_nil(scene) do
      {:error, "장면이 없습니다"}
    else
      ["info", "clean"]
      |> Enum.flat_map(&Media.list_assets(project.id, &1))
      |> Enum.filter(&(&1.scene_id == scene.id and File.exists?(&1.file_path)))
      |> List.first()
      |> case do
        nil -> {:error, "1번 장면 이미지가 없습니다"}
        a -> {:ok, a.file_path}
      end
    end
  end

  # 흰 줄 + 노란 줄. 굵은 검은 테두리로 띠 위에서도 또렷하게.
  @doc """
  띠 높이와 글자 크기를 정한다 — **띠는 상한을 넘지 않고, 글자는 그 띠 안에 들어간다.**

  세로판 띠 상한은 화면 높이의 2.5/16 (1920 → 300). 사용자 지시(2026-10-01) —
  띠가 크면 그림이 안 보이고, 글자는 띠 밖으로 나가면 안 된다.

  **줄은 쪼개지 않는다.** 7자에서 기계적으로 끊었더니 "비타민C 한 / 번에 먹으면" 처럼
  말 덩어리가 갈렸다. 한 줄씩 그대로 두고 폭·높이 둘 다에 들어가는 크기로 줄인다.

  계수는 libass 로 실제로 그려서 잰 값이다 (맑은 고딕 Bold, 크기 100):
  한글 0.75 · 공백 0.26 · 영문·숫자 약 0.5, 두 줄 간격 1.0, 글자 높이 0.73.
  (어림으로 한글 0.5 · 1.0 을 썼다가 각각 잘리고 / 너무 작아졌다.)
  """
  # **역슬래시는 두 번 쓴다.** 한 번만 쓰면 Elixir 가 먹어 화면에 글자 "N" 이 찍힌다.
  @br "\\N"
  @side 40
  # **쇼츠 타일 위쪽은 앱 UI 가 덮는다.** 글자를 띠 한가운데 두면 윗줄이 가린다
  # (실측 2026-10-02, 사용자 화면). 이만큼 내려서 UI 밑으로 보낸다.
  @top_guard 50

  @doc "세로판 띠가 시작하는 y. 테스트가 띠 위치를 알아야 글자가 띠 안에 있는지 볼 수 있다."
  def band_top, do: @band_top

  def layout(w, h, lines) do
    lines = Enum.reject(lines, &(&1 in [nil, ""]))
    n = max(length(lines), 1)
    band_max = if h > w, do: round(h * 2.5 / 16), else: 260
    pad = round(band_max * 0.08)

    # 높이: 글자 덩어리 (n-1)·1.0 + 0.73, 테두리 위아래 2 × fs/14.
    # **위쪽 여백(@top_guard)도 빼고 계산한다.** 안 빼면 글자를 내린 만큼 띠 밖으로 나간다
    # (테스트가 잡았다 — 눈으로는 "조금 내려갔네" 로 보이고 넘친 건 안 보인다).
    guard = if h > w, do: @top_guard, else: 0
    by_height = (band_max - guard - 2 * pad) / (n - 1 + 0.73 + 2 / 14)
    # 폭: 가장 긴 줄이 좌우 여백 안에 (테두리 포함)
    by_width = Enum.map(lines, &((w - 2 * @side) / (em(&1) + 2 / 14)))

    fsize = [by_height | by_width] |> Enum.min() |> floor()
    block = (n - 1 + 0.73 + 2 / 14) * fsize
    {fsize, min(band_max, round(guard + block + 2 * pad))}
  end

  # 띠 한가운데가 아니라 **아래쪽**에 둔다. 세로판에서는 위를 앱 UI 가 덮기 때문이다.
  # 띠 높이에 이미 @top_guard 가 들어 있으므로, 그 아래 남은 공간의 한가운데다.
  defp text_y(band, h, w) when h > w, do: @band_top + @top_guard + div(band - @top_guard, 2)
  defp text_y(band, _h, _w), do: div(band, 2)

  # 편마다 다른 강조색. 프로젝트 번호로 고른다 — 다시 만들어도 같은 색이다.
  defp accent(%{id: id}) when is_integer(id), do: accent_for(id)
  defp accent(_), do: hd(@accents)

  @doc false
  def accent_for(id) when is_integer(id), do: Enum.at(@accents, rem(id, length(@accents)))

  defp em(text) do
    text
    |> String.graphemes()
    |> Enum.map(fn
      " " -> 0.26
      g -> if g =~ ~r/^\p{Hangul}$/u, do: 0.75, else: 0.5
    end)
    |> Enum.sum()
  end

  defp write_ass(project, line1, line2, w, h, name) do
    path = Path.join(work_dir(project), name)
    {fsize, band} = layout(w, h, [line1, line2])
    outline = max(round(fsize / 14), 4)

    # **두 줄을 한 덩어리로 그린다.** 전에는 L1·L2 를 따로 그리고 L2 의 여백을
    # 직접 계산해 내렸는데, 그러다 행간이 한 줄 높이만큼 벌어졌다(사용자 지적 2026-10-01).
    # 한 Dialogue 안에서 줄을 바꾸면 글꼴이 정한 자연스러운 행간이 나온다.
    # 색은 중간에서 바꾼다 — 첫 줄 흰색, 둘째 줄 노란색.
    text =
      [line1, line2]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> case do
        [a] -> a
        [a, b] -> a <> @br <> "{\\c#{accent(project)}}" <> b
        [] -> ""
      end

    head = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: #{w}
    PlayResY: #{h}
    WrapStyle: 2
    ScaledBorderAndShadow: yes

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BackColour, Bold, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: L1,#{font()},#{fsize},&H00FFFFFF,&H00000000,&H00000000,1,1,#{outline},0,5,0,0,0,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.00,0:00:10.00,L1,,0,0,0,,{\\pos(#{div(w, 2)},#{text_y(band, h, w)})}#{text}
    """

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, head)
    path
  end


  defp font, do: VideoTool.Presets.default_subtitle_font()

  defp work_dir(project) do
    folder = if project.output_folder in [nil, ""], do: "projects", else: project.output_folder
    Path.join(folder, to_string(project.id))
  end

  @doc "만들어진 섬네일 파일(경로 또는 URL)을 완성본에 붙인다."
  def save(project, src) do
    with {:ok, render} <- latest_render(project),
         {:ok, path} <- place(project, src) do
      render
      |> Ecto.Changeset.change(thumbnail_path: path)
      |> VideoTool.Repo.update()
      |> case do
        {:ok, row} -> {:ok, %{render_id: row.id, thumbnail_path: path}}
        {:error, cs} -> {:error, cs}
      end
    end
  end

  defp latest_render(project) do
    case Media.latest_render(project.id, project.aspect) do
      nil -> {:error, "완성본이 아직 없습니다. 합성(assemble) 뒤에 붙이세요."}
      render -> {:ok, render}
    end
  end

  defp place(project, src) do
    dir = Path.join(["projects", "#{project.id}"])
    File.mkdir_p!(dir)
    dest = Path.join(dir, "thumb#{ext(src)}")

    cond do
      String.starts_with?(src, "http") -> download(src, dest)
      File.exists?(src) -> copy(src, dest)
      true -> {:error, "섬네일 파일을 찾을 수 없습니다: #{src}"}
    end
  end

  defp ext(src) do
    case src |> URI.parse() |> Map.get(:path) |> to_string() |> Path.extname() do
      e when e in [".jpg", ".jpeg", ".png"] -> e
      _ -> ".jpg"
    end
  end

  defp copy(src, dest) do
    if Path.expand(src) == Path.expand(dest) do
      {:ok, dest}
    else
      case File.cp(src, dest) do
        :ok -> {:ok, dest}
        {:error, r} -> {:error, "섬네일 복사 실패: #{inspect(r)}"}
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

  defp series_of(%{series_id: nil}), do: nil

  defp series_of(%{series_id: id}) do
    case Series.get(id) do
      {:ok, s} -> s
      _ -> nil
    end
  end

  defp summary(project) do
    case Projects.active_script(project.id) do
      nil -> project.topic || project.title
      script -> script.raw_text |> String.replace(~r/\s+/u, " ") |> String.slice(0, 600)
    end
  end
end
