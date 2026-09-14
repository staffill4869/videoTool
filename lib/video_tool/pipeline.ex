defmodule VideoTool.Pipeline do
  @moduledoc """
  `next/1` — 이 시스템의 단일 진입점.

  현재 상태를 보고 다음에 할 일을 정한다. 프롬프트를 낼 차례면 클립보드에 직접 넣는다
  (사용자가 파일을 열어 복사하는 일을 없애는 것이 목적이다).

  action 값:
    * `clipboard` — 클립보드에 넣었다. Flow 에서 Ctrl+V 하면 된다
    * `fix`       — 검증에 걸렸다. 문제 컷 재생성 프롬프트를 넣었다
    * `wait`      — 서버가 처리 중이다
    * `agent`     — 에이전트가 만들어서 저장해야 한다
    * `ready`     — 완성본이 준비됐다. 발행은 사용자 지시가 있어야 한다
    * `blocked`   — 아직 구현되지 않은 단계다 (설명서 3~6주차)
    * `done`      — 끝났다
  """

  alias VideoTool.{Ingest, Jobs, Media, Projects, Prompt, Publishing}

  # 테스트에서 실제 클립보드를 건드리지 않도록 갈아끼운다.
  defp clipboard, do: Application.get_env(:video_tool, :clipboard, VideoTool.Clipboard)

  # 테스트가 브라우저 유무에 좌우되면 안 된다.
  defp flow, do: Application.get_env(:video_tool, :flow, VideoTool.Flow)

  @doc "프로젝트 상태를 보고 다음 행동을 결정한다."
  def next(project) do
    scenes = Projects.scenes(project.id)
    script = Projects.active_script(project.id)

    cond do
      is_nil(script) -> need_script(project)
      scenes == [] -> need_scenes(project, script)
      Projects.allowed_facts(script.id) == [] -> need_facts(project, script)
      true -> asset_stage(project, scenes)
    end
  end

  # ── 에이전트가 만들어야 하는 것들 ───────────────────────────────

  defp need_script(project) do
    target_chars = round(project.target_sec * project.voice.chars_per_sec)

    %{
      stage: "script",
      action: "agent",
      message: "대본이 없습니다. 대본을 작성해 save_script() 로 저장하세요.",
      context: %{
        topic: project.topic,
        target_sec: project.target_sec,
        target_chars: target_chars,
        voice: project.voice.display_name,
        chars_per_sec: project.voice.chars_per_sec
      }
    }
  end

  defp need_scenes(project, script) do
    %{
      stage: "scenes",
      action: "agent",
      message: "장면 분할이 없습니다. 15~18컷으로 나눠 save_scenes() 로 저장하세요.",
      context: %{
        script_version: script.version,
        estimated_sec: script.estimated_sec,
        target_sec: project.target_sec
      }
    }
  end

  defp need_facts(_project, script) do
    %{
      stage: "facts",
      action: "agent",
      message:
        "허용 수치·명칭 화이트리스트가 비어 있습니다. save_allowed_facts() 로 저장하세요. " <>
          "이게 없으면 INFO 단계에서 대본에 없는 숫자가 화면에 렌더링됩니다.",
      context: %{script_version: script.version}
    }
  end

  # ── 이미지·클립 단계 ────────────────────────────────────────────

  defp asset_stage(project, scenes) do
    count = length(scenes)

    # Downloads 에 아직 안 가져온 zip 이 있으면 먼저 가져온다.
    # 사용자가 ingest() 를 따로 부를 필요가 없다 — 그게 이 단계의 목적이다.
    ingested = Ingest.auto(project)

    mapped = Media.mapped_counts(project.id)
    present = Media.asset_counts(project.id)

    result =
      cond do
        mapped["clean"] < count -> stage_step(project, "clean", count, present, mapped)
        mapped["info"] < count -> stage_step(project, "info", count, present, mapped)
        mapped["clip"] < count -> stage_step(project, "video", count, present, mapped)
        true -> post_production(project)
      end

    annotate_ingest(result, ingested)
  end

  defp annotate_ingest(result, :none), do: result

  defp annotate_ingest(result, {:ok, summary}) do
    warnings = Map.get(summary.validation, :warnings, [])

    result
    |> Map.put(:ingested, %{
      zip: Path.basename(summary.zip),
      extracted: summary.extracted,
      mapped: summary.mapped,
      method: summary.method,
      low_confidence: summary.low_confidence,
      unmapped: summary.unmapped
    })
    |> then(fn r -> if warnings == [], do: r, else: Map.put(r, :warnings, warnings) end)
  end

  defp annotate_ingest(result, {:error, reason}),
    do: Map.put(result, :ingest_error, reason)

  # stage 는 프롬프트 단계 이름("video"), asset kind 는 다르다("clip").
  defp asset_kind("video"), do: "clip"
  defp asset_kind(stage), do: stage

  # 한 단계를 몇 번까지 다시 시도할지. 넘으면 다시 넣지 않고 있는 것으로 진행한다.
  # 무제한으로 두면 1분마다 같은 프롬프트를 다시 넣어 크레딧만 태운다 — 실제로 그랬다.
  @max_attempts 2

  defp attempts(project_id, stage), do: Jobs.count_generations(project_id, stage)

  defp stage_step(project, stage, count, present, mapped) do
    kind = asset_kind(stage)
    validation = Jobs.latest_validation(project.id, validation_stage(stage))
    tried = attempts(project.id, stage)

    cond do
      # Flow 자동 조종이 돌고 있다 — 끼어들지 않는다
      job = Jobs.running_flow_job(project.id) ->
        %{
          stage: stage,
          action: "wait",
          message: "Flow 에서 #{job.model} 생성 중입니다. 다 되면 자동으로 받아옵니다.",
          poll_after_sec: 30,
          started_at: job.requested_at
        }

      # 검증에 걸렸다 — 문제 컷만 다시 만든다
      validation && not validation.passed && present[kind] > 0 ->
        fix_step(project, stage, validation)

      # 일부만 붙었다 — 모자란 것만 더 만든다.
      # 예전엔 여기서 "사람이 확인하세요" 로 넘겼는데, 무인 운전에서는 그 순간 파이프라인이
      # 영영 선다 (실제로 클립 12/16 에서 멈췄다). 자동화가 할 수 있는 일이면 자동화가 한다.
      # 모자란데 시도 횟수를 다 썼다 — 더 넣지 않고 있는 것으로 다음 단계로 간다.
      # 멈추는 것보다 낫고, 같은 프롬프트를 계속 넣는 것보다 낫다.
      present[kind] > 0 and mapped[kind] < count and tried >= @max_attempts ->
        skip_ahead(project, stage, count, mapped[kind])

      present[kind] > 0 and mapped[kind] < count ->
        clipboard_step(project, stage, count - mapped[kind])

      # 아무것도 없는데 시도만 다 썼다 — 여기서 더 태우지 않는다.
      tried >= @max_attempts ->
        skip_ahead(project, stage, count, mapped[kind])

      # 아직 아무것도 없다 — 프롬프트를 낸다
      true ->
        clipboard_step(project, stage, count)
    end
  end

  # 이 단계는 여기까지다. 다음 단계로 넘긴다 — 멈추지 않는 것이 우선이다.
  defp skip_ahead(_project, stage, count, got) do
    %{
      stage: stage,
      action: "wait",
      message:
        "#{stage} 를 #{@max_attempts}번 시도해 #{count}개 중 #{got}개를 얻었습니다. " <>
          "더 넣지 않고 다음 단계로 갑니다.",
      got: got,
      expected: count,
      attempts: @max_attempts
    }
  end

  defp validation_stage("video"), do: "clips"
  defp validation_stage(stage), do: stage

  defp clipboard_step(project, stage, count) do
    with {:ok, text} <- Prompt.render(project, stage) do
      # 자동이든 수동이든 클립보드에는 항상 넣는다.
      # 자동 조종이 실패해도 사람이 바로 Ctrl+V 로 이어갈 수 있어야 한다.
      clipboard_result = clipboard().put(text)

      if flow().auto?(project) do
        drive_flow(project, stage, count, text, clipboard_result)
      else
        manual_step(stage, count, text, clipboard_result)
      end
    else
      {:error, reason} -> %{stage: stage, action: "agent", message: reason}
    end
  end

  defp manual_step(stage, count, text, clipboard_result) do
    case clipboard_result do
      {:ok, chars} ->
        %{
          stage: stage,
          action: "clipboard",
          message: "Flow 탭에서 Ctrl+V 하고 생성하세요. #{count}장 나옵니다.",
          clipboard_written: true,
          prompt_chars: chars,
          next_expected: "Downloads 에 zip 이 떨어지면 자동으로 가져옵니다"
        }

      {:error, reason} ->
        %{
          stage: stage,
          action: "agent",
          message: "클립보드에 넣지 못했습니다. 아래 프롬프트를 직접 복사하세요.",
          error: reason,
          clipboard_written: false,
          prompt: text
        }
    end
  end

  # 자동 조종. 실패하면 오늘까지 쓰던 수동 방식으로 되돌아간다 —
  # Flow UI 는 바뀌게 돼 있고, 바뀌었다고 작업이 멈추면 안 된다.
  defp drive_flow(project, stage, count, text, clipboard_result) do
    # **한 편은 한 Flow 프로젝트 안에서 끝낸다.** 처음이면 열고 주소를 적어 두고,
    # 이후 단계와 재시도는 그리로 돌아간다. 단계마다 새로 열면 앞 단계 이미지가 없어
    # 두 프레임을 이어 붙일 수 없고, 재시도마다 빈 프로젝트가 쌓인다.
    case flow().project_editor(project) do
      {:ok, %{flow_tab: true, prompt_box: true}} ->
        {:ok, _job} = flow().run_stage_async(project, stage, text, count)

        %{
          stage: stage,
          action: "wait",
          message: "Flow 에 프롬프트를 넣고 생성을 눌렀습니다. #{count}장 나오면 자동으로 받아옵니다.",
          poll_after_sec: 30,
          mode: "flow_auto"
        }

      {:ok, status} ->
        fallback(stage, count, text, clipboard_result, status[:hint] || "Flow 탭이 준비되지 않았습니다")

      {:error, reason} ->
        fallback(stage, count, text, clipboard_result, reason)
    end
  end

  defp fallback(stage, count, text, clipboard_result, reason) do
    stage
    |> manual_step(count, text, clipboard_result)
    |> Map.put(:flow_auto_unavailable, reason)
    |> Map.update!(:message, &"자동 조종을 못 썼습니다 (#{reason}) 수동으로 진행하세요. #{&1}")
  end

  defp fix_step(project, stage, validation) do
    problems = validation.problems || []
    scene_no = problems |> List.first() |> then(&(&1 && &1["scene_no"]))

    with {:ok, text} <- Prompt.render(project, stage, scene_no: scene_no, problems: problems) do
      {written, chars} =
        case clipboard().put(text) do
          {:ok, n} -> {true, n}
          {:error, _} -> {false, 0}
        end

      %{
        stage: stage,
        action: "fix",
        message: fix_message(problems),
        problems: problems,
        clipboard_written: written,
        prompt_chars: chars
      }
    else
      {:error, reason} -> %{stage: stage, action: "agent", message: reason}
    end
  end

  defp fix_message([]), do: "검증에 실패했지만 문제 목록이 비어 있습니다."

  defp fix_message([first | rest]) do
    tail = if rest == [], do: "", else: " (외 #{length(rest)}건)"
    "#{first["scene_no"]}번 컷: #{first["issue"]}#{tail} 재생성 프롬프트를 클립보드에 넣었습니다."
  end

  # ── 나레이션 · 합성 · 발행 ──────────────────────────────────────

  defp post_production(project) do
    narration = Media.latest_narration(project.id)
    render = Media.latest_render(project.id, project.aspect)

    cond do
      is_nil(narration) ->
        # 서버에는 TTS 키가 없다. 음성은 힉스필드 MCP 를 쓸 수 있는 에이전트가 만들어
        # save_narration 으로 넣는다 — next_job 이 make_narration 으로 내준다.
        %{
          stage: "narration",
          action: "agent",
          message:
            "클립이 모두 준비됐습니다. 힉스필드 MCP 로 음성을 만들어 " <>
              "save_narration(project_id, file) 로 넘기세요. 낭독 속도로 길이를 맞추지 마세요.",
          scenes_ready: true,
          script: script_text(project)
        }

      is_nil(render) ->
        # 예전엔 여기서 "아직 구현되지 않았습니다" 를 돌려줬는데 Assembly 는 이미 있다.
        # 그 문구 때문에 나레이션까지 끝나고도 파이프라인이 영영 섰다.
        case VideoTool.Assembly.assemble(project, burn: true) do
          {:ok, result} ->
            result
            |> Map.put(:stage, "assemble")
            |> Map.put(:action, "wait")
            |> Map.put(:message, "합성했습니다. 발행은 지시가 있어야 나갑니다.")

          {:error, reason} ->
            %{
              stage: "assemble",
              action: "agent",
              message: "합성하지 못했습니다: #{inspect(reason)}",
              narration_sec: narration.duration_sec
            }
        end

      true ->
        ready_to_publish(project)
    end
  end

  defp script_text(project) do
    case Projects.active_script(project.id) do
      nil -> nil
      s -> s.tts_text || s.raw_text
    end
  end

  # 자동으로 발행하지 않는다. 되돌리기 어려운 공개 행위라서 여기서 멈춘다.
  defp ready_to_publish(project) do
    renders = Media.renders(project.id)

    %{
      stage: "publish",
      action: "ready",
      message: "완성본과 세로본이 준비됐습니다. 발행하려면 지시해 주세요.",
      renders: Enum.map(renders, &%{id: &1.id, aspect: &1.aspect, path: &1.file_path}),
      channels: Enum.map(Publishing.list_channels(), & &1.slug)
    }
  end
end