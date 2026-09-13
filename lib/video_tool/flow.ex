defmodule VideoTool.Flow do
  @moduledoc """
  Flow 브라우저 조종. `priv/flow_driver/driver.mjs` 를 한 동작마다 한 번씩 부른다.

  Flow 에는 API 가 없어서 UI 를 직접 조종하는 것 외에 방법이 없다. 대신 세 가지를 지킨다.

    1. **로그인은 사람이 한다.** 이미 로그인된 Chrome 에 CDP 로 붙을 뿐 자격증명을 만지지 않는다
    2. **요청량을 늘리지 않는다.** 사람이 하던 것을 같은 속도로 대신한다
    3. **깨지면 수동으로 되돌아간다.** 버튼을 못 찾으면 프롬프트를 클립보드에 넣고 사람에게 넘긴다

  UI 가 바뀌었을 때 고칠 곳은 이 파일이 아니라 `priv/flow_driver/selectors.json` 이다.
  """

  require Logger

  alias VideoTool.{Ffmpeg, Jobs, Mapping, Media, Phash}

  @default_timeout 30_000

  @doc """
  Flow 용 Chrome 을 디버그 포트로 띄운다.

  평소 쓰는 Chrome 을 쓰지 않는 이유: 기본 프로필로 이미 떠 있으면
  `--remote-debugging-port` 가 조용히 무시된다. 전용 프로필을 쓴다.
  """
  def open_browser do
    script = Path.join(File.cwd!(), "launch-chrome.ps1")

    if File.exists?(script) do
      # PowerShell 은 콘솔 코드페이지(한국어 Windows 면 CP949)로 뱉는다. 그대로 들고 오면
      # 한글이 깨진 바이트로 남고, MCP 응답을 Jason.encode! 할 때 통째로 터진다.
      # 출력 인코딩을 UTF-8 로 강제하고, 그래도 남는 깨진 바이트는 아래에서 걸러낸다.
      command =
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8; " <>
          "& '#{String.replace(script, "'", "''")}'"

      case System.cmd("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          {:ok, out |> utf8_only() |> String.trim()}

        {out, code} ->
          {:error, "Chrome 을 띄우지 못했습니다 (exit #{code}): #{out |> utf8_only() |> String.slice(0, 300)}"}
      end
    else
      {:error, "launch-chrome.ps1 이 없습니다: #{script}"}
    end
  rescue
    e in ErlangError -> {:error, "powershell 실행 실패: #{inspect(e.original)}"}
  end

  @doc "새 Flow 프로젝트를 연다. 편마다 따로 열어야 이전 편 이미지가 섞이지 않는다."
  def new_project, do: run(%{action: "new_project"}, 120_000)

  @doc """
  Flow 프로젝트에 상시 지시를 박는다.

  본문에만 적으면 긴 프롬프트에서 흘린다. 매번 지켜야 하는 것은 본문이 아니라
  여기에 넣어야 프로젝트 전체에 적용된다.
  """
  def set_guideline(text, title \\ "제작 규칙") do
    run(%{action: "set_guideline", text: text, title: title}, 120_000)
  end

  @doc """
  이 프로젝트에 맞는 Flow 프로젝트를 열고 상시 지시까지 넣는다.

  새 프로젝트를 열 때마다 지시가 비므로, 여는 것과 지시를 넣는 것은 한 몸으로 둔다 —
  따로 두면 지시 없는 프로젝트에서 생성이 돌아 화면비가 틀어진다.
  """
  def open_for(project) do
    with {:ok, opened} <- new_project() do
      # 상시 지시는 **부수적인 단계**다. 여기서 실패했다고 편집기를 여는 일까지
      # 통째로 실패시키면 안 된다 — 실제로 '안내 추가' 버튼 이름이 바뀌자
      # CLEAN 단계가 시작조차 못 했다. 화면비는 프롬프트 본문에도 장면마다 들어간다.
      case set_guideline(guideline_for(project)) do
        {:ok, _} ->
          {:ok, opened}

        {:error, reason} ->
          Logger.warning("상시 지시를 못 넣었습니다 (계속 진행): #{reason}")
          {:ok, Map.put(opened, :guideline_error, reason)}
      end
    end
  end

  defp guideline_for(project) do
    aspect = project.aspect || "16:9"

    orientation =
      if aspect == "9:16" do
        "세로로 만든다. 가로로 만들지 않는다. 인물과 핵심 대상은 화면 가운데 세로축에 두고 좌우는 비운다."
      else
        "가로로 만든다. 세로로 만들지 않는다. 좌우로 넓게 쓰고 여백은 한쪽에 몰아 둔다."
      end

    """
    모든 이미지와 영상은 반드시 #{aspect} 비율로 만든다. #{orientation}
    화면 아래 20퍼센트에는 나중에 자막이 얹히므로 글자나 핵심 대상을 두지 않는다.
    요청한 장면 수를 그대로 지킨다. 임의로 늘리거나 줄이지 않는다.
    일부가 실패하면 실패한 것만 다시 만들어 요청한 개수를 채운다.
    요청한 것만 하고 멈춘다. 다음 단계를 스스로 제안하거나 이어서 하지 않는다 —
    이미지를 만들라고 하면 이미지까지, 영상을 만들라고 할 때만 영상을 만든다.
    """
  end

  @doc """
  프롬프트를 넣을 수 있는 상태인지 확인하고, 아니면 만든다.

  Flow 홈이나 소개 화면에는 입력칸이 없다. 예전엔 여기서 "사람이 프로젝트를 열어달라"로
  멈췄는데, 자동화가 할 수 있는 일이었다 — 무인으로 돌리려면 스스로 열어야 한다.
  로그인 화면일 때만 사람을 부른다. 자격증명은 자동화가 만지지 않는다.
  """
  def ensure_editor(project) do
    case status() do
      {:ok, %{page: "editor", prompt_box: true}} = ok ->
        ok

      {:ok, %{page: "login"}} ->
        {:error, "구글 로그인 화면입니다. 사람이 직접 로그인해야 합니다 — 자동화는 로그인하지 않습니다."}

      {:ok, _} ->
        # 홈·소개·입력칸 없는 편집기 — 새 프로젝트를 열어 본다.
        # `new_project` 가 아니라 `open_for` 를 쓴다: 새로 열면 상시 지시가 비어서
        # 화면비 규칙 없이 생성이 돌아간다.
        with {:ok, _} <- open_for(project), do: status()

      other ->
        other
    end
  end

  @doc """
  새 Flow 프로젝트를 열고 상태를 돌려준다. 한 편의 첫 단계(CLEAN)용.

  남이 쓰던 탭에 그대로 붙여넣으면 그 대화에 있던 이미지가 섞이고, Flow 에이전트가
  그걸 보고 제멋대로 다음 단계를 제안한다 — CLEAN 을 시켰는데 영상 18개를 만들려 한 적이 있다.
  """
  def fresh_editor(project) do
    with {:ok, _} <- open_for(project), do: status()
  end

  @doc "Chrome 에 붙을 수 있는지, Flow 탭이 열려 있는지."
  def status, do: run(%{action: "status"}, @default_timeout)

  @doc "프롬프트를 넣고 생성 버튼을 누른다."
  def paste_and_generate(prompt) do
    run(%{action: "paste_and_generate", prompt: prompt}, 60_000)
  end

  @doc """
  결과가 `expect` 개 나올 때까지 기다린다.
  Veo 는 분 단위로 걸리므로 기본 15분을 준다.
  """
  def wait_results(expect, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 900_000)
    since = Keyword.get(opts, :since, 0)
    # 단계를 넘겨야 드라이버가 "이 단계에서 눌러도 되는 선택지" 를 구분한다.
    # 영상 단계에서만 '생성된 이미지로 영상 만들기' 를 누른다 — 이미지 단계에서 누르면 새 나간다.
    stage = Keyword.get(opts, :stage, "")

    run(
      %{action: "wait_results", expect: expect, timeoutMs: timeout, since: since, stage: stage},
      timeout + 30_000
    )
  end

  @doc "프로젝트 다운로드를 누른다. 받은 파일은 Downloads 감시가 가져간다."
  def download, do: run(%{action: "download"}, 60_000)

  @doc """
  화면에 있는 결과물을 받아 자산으로 등록하고 장면에 배정한다.

  Flow 의 다운로드 버튼을 쓰지 않는다 — zip 으로 묶여 나와 어느 게 어느 장면인지
  알 수 없다. 대신 화면의 주소를 그대로 받고, **이미 등록한 것은 건너뛴다**.
  단계를 이어 돌려도 CLEAN 을 INFO 로 잘못 세지 않게 하려는 것이다.

  배정은 `Mapping` 이 한다 — CLEAN 은 순서대로, INFO 는 CLEAN 과 닮은 정도로,
  클립은 첫 프레임이 CLEAN 과 끝 프레임이 INFO 와 닮았는지로 (by_chain).
  """
  def harvest(project, stage) do
    kind = asset_kind(stage)
    dir = Path.join(project.work_dir, "incoming")
    known = known_flow_ids(project.id)

    with {:ok, %{files: files}} <-
           run(%{action: "harvest", dir: dir, kind: media_kind(kind), known: known}, 300_000) do
      assets = Enum.flat_map(files, &register(project, kind, &1))

      if assets == [] do
        {:ok, %{kind: kind, new: 0, note: "새로 받은 것이 없습니다 (이미 다 등록했거나 결과가 없습니다)"}}
      else
        placed = Mapping.assign(project, kind, assets)
        apply_placement(placed)

        {:ok,
         %{
           kind: kind,
           new: length(assets),
           placed: map_size(placed),
           low_confidence: count_low(placed)
         }}
      end
    end
  end

  # 프롬프트 단계 이름과 자산 종류가 다르다. video 단계가 만드는 건 clip 이다.
  defp asset_kind("video"), do: "clip"
  defp asset_kind(stage), do: stage

  defp media_kind("clip"), do: "video"
  defp media_kind(_), do: "image"

  # 같은 걸 두 번 등록하지 않는다. Flow 가 준 식별자를 source_filename 에 남겨 대조한다.
  defp known_flow_ids(project_id) do
    ~w(clean info clip)
    |> Enum.flat_map(&Media.list_assets(project_id, &1))
    |> Enum.map(& &1.source_filename)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp register(project, kind, %{"id" => id, "path" => path, "type" => type}) do
    if File.exists?(path) do
      probe = case Ffmpeg.probe(path) do
        {:ok, p} -> p
        _ -> %{width: 0, height: 0, duration_sec: nil, fps: nil}
      end

      attrs = %{
        project_id: project.id,
        kind: kind,
        source: "flow",
        file_path: path,
        source_filename: id,
        width: probe.width,
        height: probe.height,
        duration_sec: probe.duration_sec,
        fps: probe.fps,
        phash: hash(path, :first),
        # 영상은 끝 프레임 해시가 있어야 INFO 와 짝지을 수 있다. 이미지는 둘이 같다.
        phash_last: if(type == "video", do: hash(path, :last), else: hash(path, :first))
      }

      case Media.create_asset(attrs) do
        {:ok, asset} -> [asset]
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp register(_project, _kind, _), do: []

  defp hash(path, at) do
    case Phash.of_file(path, at) do
      {:ok, h} -> h
      _ -> ""
    end
  end

  defp apply_placement(placed) do
    Enum.each(placed, fn {asset_id, {scene_id, confidence}} ->
      case Media.get_asset(asset_id) do
        nil -> :ok
        asset -> Media.update_asset(asset, %{scene_id: scene_id, order_confidence: confidence})
      end
    end)
  end

  defp count_low(placed) do
    Enum.count(placed, fn {_, {_, c}} -> Mapping.low_confidence?(c) end)
  end

  @doc "이 프로젝트가 Flow 자동 조종을 쓰는가."
  def auto?(%{pipeline: "flow_auto"}), do: true
  def auto?(_), do: false


  @doc """
  한 단계(붙여넣기 → 생성 → 대기 → 수확)를 백그라운드로 돌린다.

  Veo 는 분 단위로 걸린다. MCP 호출이 그동안 붙잡혀 있으면 클라이언트가 먼저 끊는다.
  그래서 진행 상태를 GenerationJob 행에 남기고 `next/1` 은 곧바로 `wait` 를 돌려준다.
  """
  def run_stage_async(project, stage, prompt, expect) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, job} =
      Jobs.record_generation(%{
        project_id: project.id,
        provider: "flow",
        model: stage,
        status: "running",
        requested_at: now
      })

    Task.Supervisor.start_child(VideoTool.TaskSupervisor, fn ->
      run_stage(job, project, stage, prompt, expect)
    end)

    {:ok, job}
  end

  # 다운로드 버튼을 누르지 않는다. 생성이 끝나면 곧바로 화면에서 받아 자산으로 등록한다 —
  # 버튼은 zip 으로 묶어 주는데, 묶이면 어느 게 어느 장면인지 알 방법이 사라진다.
  # 대기 로직이 "다 됐다" 고 해도 **회수한 개수로 검증**한다.
  # 화면의 숫자를 세는 방식은 Flow 가 대기열에 등록만 한 상태에서도 통과한 적이 있다
  # (125초 만에 done, 클립 0개). 진짜 증거는 받아온 파일 수다.
  @harvest_rounds 4

  defp run_stage(job, project, stage, prompt, expect) do
    result =
      with {:ok, started} <- paste_and_generate(prompt) do
        since = started[:results_before] || 0
        collect(project, stage, expect, since, @harvest_rounds, 0)
      end

    finish(job, result)
  end

  defp collect(project, stage, expect, since, rounds_left, got) do
    with {:ok, _} <- wait_results(expect - got, since: since, stage: stage),
         {:ok, harvested} <- harvest(project, stage) do
      got = got + (harvested[:new] || 0)

      cond do
        got >= expect -> {:ok, harvested}
        rounds_left <= 1 -> {:ok, harvested}
        true -> collect(project, stage, expect, since, rounds_left - 1, got)
      end
    end
  end

  defp finish(job, {:ok, harvested}) do
    Jobs.finish_generation(job, "done", summarize(harvested))
  end

  defp finish(job, {:error, reason}) do
    Logger.error("Flow 자동 조종 실패: #{reason}")
    Jobs.finish_generation(job, "failed", reason)
  end

  # 낮은 신뢰도로 배정된 게 있으면 사람이 봐야 한다. 조용히 넘어가면 엉뚱한 장면에 붙은 채로 합성된다.
  defp summarize(%{new: new, placed: placed, low_confidence: low}) do
    base = "#{new}개 받아 #{placed}개 배정"
    if low > 0, do: base <> " — 신뢰도 낮음 #{low}건, 화면에서 확인 필요", else: base
  end

  defp summarize(%{note: note}), do: note
  defp summarize(_), do: ""

  # 외부 프로그램 출력에서 UTF-8 이 아닌 바이트를 버린다.
  # MCP 응답은 JSON 이라 한 바이트만 깨져도 응답 전체가 나가지 못한다 —
  # 깨진 글자 몇 개를 잃는 게 응답을 통째로 잃는 것보다 낫다.
  defp utf8_only(text) do
    text
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
  end

  # ── 실행 ────────────────────────────────────────────────────────

  defp run(command, timeout) do
    script = Path.join([:code.priv_dir(:video_tool), "flow_driver", "driver.mjs"])

    if File.exists?(script) do
      execute(script, command, timeout)
    else
      {:error, "driver.mjs 가 없습니다: #{script}"}
    end
  end

  # 명령 JSON 을 argv 로 넘기지 않는다. 프롬프트가 7천 자를 넘고 큰따옴표를 품고 있어서
  # Windows 명령줄 인용 처리에서 깨진다 (`"움직이는 3D 장면"` 이 `\움직이는` 이 되어 JSON 파싱 실패).
  # 임시 파일에 UTF-8 로 쓰고 경로만 넘긴다 — 길이 제한도 인용 문제도 없앤다.
  defp execute(script, command, timeout) do
    path =
      Path.join(System.tmp_dir!(), "flow_cmd_#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(command))

    task =
      Task.async(fn ->
        try do
          System.cmd("node", [script, "--file", path], stderr_to_stdout: true)
        after
          File.rm(path)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> decode(output, command)
      {:ok, {output, code}} -> {:error, "driver 종료 코드 #{code}: #{String.slice(output, 0, 400)}"}
      nil -> {:error, "driver 응답 없음 (#{div(timeout, 1000)}초)"}
    end
  rescue
    e in ErlangError -> {:error, "node 를 실행할 수 없습니다: #{inspect(e.original)}"}
  end

  # driver 는 마지막 줄에 JSON 을 뱉는다. 앞줄은 node 경고일 수 있다.
  defp decode(output, command) do
    line =
      output
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find(&String.starts_with?(String.trim(&1), "{"))

    case line && Jason.decode(line) do
      {:ok, %{"ok" => true} = result} ->
        {:ok, atomize(result)}

      {:ok, %{"ok" => false, "error" => error}} ->
        Logger.warning("Flow #{command.action} 실패: #{error}")
        {:error, error}

      _ ->
        {:error, "driver 응답을 읽지 못했습니다: #{String.slice(output, 0, 400)}"}
    end
  end

  defp atomize(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end
end