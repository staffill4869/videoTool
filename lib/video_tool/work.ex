defmodule VideoTool.Work do
  @moduledoc """
  에이전트가 다음에 할 일을 찾아 준다.

  서버에는 LLM 이 없다. 그래서 서버가 대본을 쓸 수는 없고, **대신 할 일을 계속 내준다.**
  Claude Code 가 MCP 로 붙어 있으면 `next_job` 을 반복해 부르는 것만으로 여러 프로젝트를
  이어서 처리할 수 있다.

  여기서 내주는 것은 **에이전트만 할 수 있는 일** 세 가지뿐이다.
  기계가 할 일(생성·수집·매핑·합성)과 사람이 할 일(발행)은 내주지 않는다 —
  섞어 내면 에이전트가 자기가 못 하는 일을 붙잡고 있게 된다.
  """

  import Ecto.Query

  alias VideoTool.{Projects, Repo, Series}
  alias VideoTool.Projects.Project

  @doc "가장 먼저 처리해야 할 일 하나. 없으면 `{:ok, nil}`."
  def next_job do
    case pending_jobs(1) do
      [job] -> {:ok, job}
      [] -> {:ok, nil}
    end
  end

  # 한 번에 훑을 프로젝트 수. 이보다 많으면 앞쪽부터 처리하면 된다.
  @scan_limit 200

  @doc """
  대기 중인 일 목록. 오래된 프로젝트부터.

  **DB 에서 먼저 자르고 거르면 안 된다.** 가장 오래된 프로젝트가 이미 끝난 것이면
  거른 뒤에 아무것도 안 남아서 "할 일 없음" 이 된다 — 뒤쪽에 일이 쌓여 있는데도.
  넉넉히 훑고 거른 다음에 자른다.
  """
  def pending_jobs(limit \\ 20) do
    Repo.all(
      from p in Project,
        where: p.status in ["draft", "scripted", "scened"],
        order_by: [asc: p.inserted_at],
        limit: @scan_limit,
        preload: [:style, :domain, :voice]
    )
    |> Enum.map(&describe/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(limit)
  end

  defp describe(project) do
    script = Projects.active_script(project.id)
    scenes = Projects.scenes(project.id)

    cond do
      # 언어판은 새로 쓰는 게 아니라 원본을 옮기는 것이다. 새로 쓰라고 내주면
      # 같은 영상인데 내용이 달라진다 — CLEAN 이미지를 공유하는 의미가 없어진다.
      is_nil(script) and project.variant_of_id -> job(project, "translate_script", script)
      is_nil(script) -> job(project, "write_script", script)
      scenes == [] and project.variant_of_id -> job(project, "translate_scenes", script)
      scenes == [] -> job(project, "split_scenes", script)
      Projects.allowed_facts(script.id) == [] -> job(project, "write_allowed_facts", script)
      # 클립이 다 붙었는데 나레이션이 없으면 그것도 에이전트 몫이다.
      # 서버는 TTS 키를 들고 있지 않다 — 음성은 힉스필드 MCP 를 쓸 수 있는 쪽이 만든다.
      # 이걸 안 내주면 클립이 다 나와도 아무도 안 집어가서 파이프라인이 거기서 선다.
      needs_narration?(project, scenes) -> job(project, "make_narration", script)
      # 나머지는 기계나 사람 몫이다. 에이전트에게 내주지 않는다.
      true -> nil
    end
  end

  defp needs_narration?(project, scenes) do
    count = length(scenes)

    count > 0 and
      Map.get(VideoTool.Media.mapped_counts(project.id), "clip", 0) >= count and
      is_nil(VideoTool.Media.latest_narration(project.id))
  end

  # 영상이 다 나온 뒤에만 의미가 있다. 대본을 여기에 맞춰 쓰라고 실측값을 준다.
  defp clip_total_sec(project, "make_narration") do
    VideoTool.Media.list_assets(project.id, "clip")
    |> Enum.filter(& &1.scene_id)
    |> Enum.map(&(&1.duration_sec || 0))
    |> Enum.sum()
    |> Float.round(1)
  end

  defp clip_total_sec(_project, _task), do: nil

  defp job(project, task, script) do
    %{
      task: task,
      project_id: project.id,
      title: project.title,
      topic: project.topic,
      target_sec: project.target_sec,
      target_chars: round(project.target_sec * project.voice.chars_per_sec),
      chars_per_sec: project.voice.chars_per_sec,
      voice: project.voice.display_name,
      style: project.style.name,
      domain: project.domain.name,
      script_version: script && script.version,
      estimated_sec: script && script.estimated_sec,
      language: project.language,
      language_label: Projects.language_label(project.language),
      variant_of_id: project.variant_of_id,
      clip_total_sec: clip_total_sec(project, task),
      source: source_material(project, task),
      standing_prompt: standing_prompt(project),
      instruction: instruction(task)
    }
  end

  # 언어판이면 원본의 대본·장면을 함께 준다. 없으면 옮길 대상을 모른다.
  defp source_material(%{variant_of_id: nil}, _task), do: nil

  defp source_material(project, task) when task in ["translate_script", "translate_scenes"] do
    with {:ok, origin} <- Projects.get_project(project.variant_of_id) do
      script = Projects.active_script(origin.id)

      %{
        project_id: origin.id,
        language: Projects.language_label(origin.language),
        script: script && script.raw_text,
        scenes:
          Enum.map(Projects.scenes(origin.id), fn s ->
            %{scene_no: s.scene_no, target_sec: s.target_sec, info_instruction: s.info_instruction}
          end)
      }
    else
      _ -> nil
    end
  end

  defp source_material(_project, _task), do: nil

  # 시리즈로 만들어진 프로젝트면 그 시리즈의 상시 프롬프트를 함께 준다 —
  # "계속 하나의 프롬프트로 찍어낸다" 가 이걸로 성립한다.
  defp standing_prompt(%{series_id: nil}), do: nil

  defp standing_prompt(%{series_id: id}) do
    case Series.get(id) do
      {:ok, series} -> %{series: series.name, brief: series.topic_brief, prompt: series.standing_prompt}
      _ -> nil
    end
  end

  # 자막은 이 글이 그대로 구워진다 — 완성본에서 고치려면 전부 다시 합성해야 한다.
  # 실제로 나간 것들: "그 곡물은 어디서 오나." (물음표 없음), "같은 많이 먹었다는 말이"
  # (따옴표가 빠져 비문), "살아 남는" (한 단어인데 띄웠다).
  @proofread """

  **저장하기 전에 오타를 한 번 훑으세요.** 이 글이 자막으로 그대로 구워집니다.
  - 맞춤법·띄어쓰기: 한 단어는 붙입니다 (살아남다 · 빠져나가다 · 쌓아두다)
  - 의문문은 반드시 ? 로 끝냅니다. 문장 끝 마침표·물음표·느낌표로 자막을 나누므로,
    빠지면 두 문장이 한 줄로 붙습니다
  - 낱말을 인용할 때는 따옴표를 넣습니다 (같은 "많이 먹었다"는 말이)
  - 두 뜻으로 읽히는 낱말은 바꿉니다 (흡수 이야기의 "태워 주다" → "실어 나르다")
  - 소리 내어 읽어 걸리는 곳은 TTS 도 걸립니다
  """

  # 마지막 장면을 요약으로 닫으면 사람들이 "그렇구나" 하고 나간다.
  # 질문으로 끝내면 댓글에 자기 경험과 판단을 쓴다 — 그게 노출로 돌아온다.
  defp instruction("write_script"),
    do:
      "대본을 써서 save_script(project_id, raw_text) 로 저장하세요. " <>
        "한 장면은 클립 길이(8초)에 맞춰 공백 제외 38~42자로 씁니다 " <>
        "(ElevenLabs 실측 초당 5.0자). 짧게 쓰면 장면마다 침묵이 생기고, " <>
        "만든 영상을 그만큼 버리게 됩니다.
" <>
        "**마지막 장면은 질문으로 끝냅니다.** 요약으로 닫지 말고, 본 사람이 " <>
        "댓글에 자기 경험이나 판단을 쓰게 만드는 질문 한 문장으로 마칩니다:
" <>
        "- 영상에서 다룬 내용을 근거로 답할 수 있는 질문일 것 (딴 이야기 금지)
" <>
        "- 예·아니오로 끝나지 않게, 의견이 갈리는 지점을 물을 것 " <>
        "(\"어느 쪽이…\", \"당신이라면…\", \"이건 왜…\")
" <>
        "- 구독·좋아요·댓글 요청 문구는 넣지 말 것. 질문 자체가 초대다
" <>
        "- 마지막 장면도 8초짜리다. 짧은 마무리 한 마디 + 질문으로 38~42자를 채울 것
" <>
        "  예) \"직선은 시간을 아끼려는 계산이었습니다. 지금 우리가 쓰는 길은 " <>
        "무엇을 아끼려고 그렇게 놓였을까요?\"" <> @proofread

  defp instruction("split_scenes"),
    do:
      "대본을 장면으로 나눠 save_scenes(project_id, scenes) 로 저장하세요. " <>
        "장면 8개, 각 target_sec 은 8입니다 — Flow 클립이 8초로 나옵니다. " <>
        "shot_prompt · info_instruction · camera_plan · expected_labels 를 채우세요. " <>
        "마지막 장면(purpose: close)의 segment_text 는 질문으로 끝나야 합니다." <> @proofread

  defp instruction("translate_script"),
    do:
      "원본 대본을 이 언어로 옮겨 save_script(project_id, raw_text) 로 저장하세요. " <>
        "새로 쓰지 마세요 — 같은 영상의 다른 언어판입니다. 화면(CLEAN)은 원본과 같은 그림을 씁니다. " <>
        "estimate_length 로 길이를 확인하세요. 언어마다 글자 수가 달라 길이가 어긋납니다."

  defp instruction("translate_scenes"),
    do:
      "원본의 장면 구성을 그대로 두고 info_instruction 과 expected_labels 만 이 언어로 옮겨 " <>
        "save_scenes 로 저장하세요. shot_prompt·camera_plan·target_sec 은 원본과 같아야 합니다."

  # **TTS 를 먼저 만들지 않는다.** 영상이 이미 나와 있으므로 그 길이가 곧 정답이다.
  # 대본 60초 목표로 썼는데 클립이 8초씩 나와 120초가 된 적이 있다 — 뒤 53초가 무음이었다.
  # 길이를 아는 지금 대본을 그 길이에 맞춰 다시 쓰고, 그 다음에 음성을 만든다.
  defp instruction("make_narration"),
    do:
      "**먼저 대본 길이를 영상에 맞추세요.** clip_total_sec 이 이번 영상의 실제 길이입니다. " <>
        "지금 대본이 그보다 짧으면 save_script 로 내용을 더 써서 길이를 맞춘 뒤에 음성을 만드세요 " <>
        "(estimate_length 로 확인). 짧은 대본으로 음성을 만들면 뒷부분이 통째로 무음이 됩니다. " <>
        "길이를 맞췄으면 힉스필드 MCP 로 TTS 를 만들고 그 파일 경로나 URL 을 " <>
        "save_narration(project_id, file) 에 넘기세요. " <>
        "낭독 속도를 올려 길이를 맞추지 마세요 — 글자 수로 맞춥니다. " <>
        "저장이 끝나면 서버가 합성까지 이어서 합니다." <> @proofread

  defp instruction("write_allowed_facts"),
    do:
      "화면에 넣어도 되는 수치·명칭을 save_allowed_facts(project_id, facts) 로 저장하세요. " <>
        "이게 없으면 INFO 단계에서 대본에 없는 숫자가 렌더링됩니다."

  @doc "지금 시스템이 어떤 상태인지 한눈에. 에이전트가 루프를 계속 돌지 판단하는 근거."
  def summary do
    jobs = pending_jobs(100)

    %{
      pending_jobs: length(jobs),
      by_task: Enum.frequencies_by(jobs, & &1.task),
      active_series:
        Repo.one(from s in Series.Recipe, where: s.active, select: count(s.id)) || 0,
      projects: Repo.one(from p in Project, select: count(p.id)) || 0
    }
  end
end