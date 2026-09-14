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
  ## 공통 규칙

  - 크기 #{@size} (16:9), JPG 또는 PNG, 2MB 이하. 세로 영상이어도 섬네일은 가로다.
  - **프로젝트 이름·시리즈 이름·회차 번호를 넣지 마라.** "영양제, 왜 그런가 #1" 같은
    관리용 제목은 시청자에게 아무 의미가 없다.
  - 글자는 **제목 하나뿐**. 2~5글자로 짧고 강하게. 설명하지 말고 찌른다.
    좋은 예: "왜 노랗지", "흡수 0%", "밤에 먹어라", "상자의 이유"
    나쁜 예: "비타민의 수용성과 지용성 차이를 알아봅시다"
  - 제목은 **네 귀퉁이 중 한 곳에** 작게 넣는다. 가운데를 가리지 마라 —
    가운데는 그림이 말하는 자리다.
  - 글자는 굵은 고딕, 흰색 또는 검정에 반대색 테두리. 폰에서 엄지만 한 크기로 봐도 읽혀야 한다.
  - 그림 안에 다른 글자(라벨·숫자·로고·워터마크)는 넣지 마라.
  - 영상 본편의 그림체를 따른다. 전혀 다른 화풍이면 눌러 놓고 딴 영상이 열린 느낌이 난다.
  """

  @before_after """
  ## 구성 — 먹기 전 / 먹은 후 (이 시리즈 전용)

  화면을 **좌우로 반 갈라** 같은 것을 두 번 보여 준다. 이게 이 시리즈 섬네일의 뼈대다.

  - 왼쪽 = 영양제를 먹기 **전**, 오른쪽 = 먹은 **후**
  - **같은 대상, 같은 각도, 같은 거리.** 달라지는 건 이번 편이 설명하는 그 한 가지뿐이다.
    (대상이 바뀌면 비교가 아니라 다른 그림 두 장이 된다)
  - 가운데 경계선은 얇고 선명하게. 화살표 하나를 넣어도 좋다.
  - 왼쪽은 가라앉은 색, 오른쪽은 밝은 색으로 차이를 색으로도 만든다
  - "BEFORE / AFTER" 같은 글자는 **넣지 마라.** 좌우 배치와 색만으로 읽힌다.
  - 제목 2~5글자는 아래 두 귀퉁이 중 한 곳.
  """

  @single """
  ## 구성

  - 장면 하나를 크게. 영상에서 가장 이상하거나 궁금한 순간을 고른다
  - 답이 아니라 **질문이 보이게** 한다. 다 보여 주면 누를 이유가 없다
  - 배경은 단순하게. 주인공 하나만 또렷하게 남긴다
  """

  @doc """
  이 프로젝트의 섬네일 지시문. 코워크·에이전트가 그대로 읽고 그리면 된다.
  """
  def brief(project) do
    series = series_of(project)
    layout = if supplement?(series, project), do: @before_after, else: @single

    """
    # 섬네일 지시문 — #{project.title}

    이 영상의 내용: #{summary(project)}

    #{layout}
    #{@common}

    ## 제목 정하기

    영상에서 가장 놀라운 한 가지를 2~5글자로 줄인다. 시리즈 이름이 아니라 **이번 편의 내용**이다.
    다 만들었으면 save_thumbnail(project_id, file) 로 넘긴다.
    """
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

  # 시리즈가 없는 낱개 프로젝트도 제목으로 판단한다 — 초기 영양제 편들이 여기 해당한다.
  defp supplement?(series, project) do
    text = "#{series && series.name} #{project.title} #{project.topic}"
    String.contains?(text, ["영양제", "비타민", "유산균", "마그네슘", "철분"])
  end

  defp summary(project) do
    case Projects.active_script(project.id) do
      nil -> project.topic || project.title
      script -> script.raw_text |> String.replace(~r/\s+/u, " ") |> String.slice(0, 600)
    end
  end
end
