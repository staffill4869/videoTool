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
