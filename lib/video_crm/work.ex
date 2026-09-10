defmodule VideoCRM.Work do
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

  alias VideoCRM.{Projects, Repo, Series}
  alias VideoCRM.Projects.Project

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
      # 나머지는 기계나 사람 몫이다. 에이전트에게 내주지 않는다.
      true -> nil
    end
  end

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

  defp instruction("write_script"),
    do:
      "대본을 써서 save_script(project_id, raw_text) 로 저장하세요. " <>
        "estimate_length 로 길이를 먼저 확인하세요 — 목표 글자수를 넘기면 TTS 가 두 배로 나옵니다."

  defp instruction("split_scenes"),
    do:
      "대본을 장면으로 나눠 save_scenes(project_id, scenes) 로 저장하세요. " <>
        "각 장면은 3~4초, 5초를 넘기지 마세요. shot_prompt · info_instruction · " <>
        "camera_plan · expected_labels 를 채우세요."

  defp instruction("translate_script"),
    do:
      "원본 대본을 이 언어로 옮겨 save_script(project_id, raw_text) 로 저장하세요. " <>
        "새로 쓰지 마세요 — 같은 영상의 다른 언어판입니다. 화면(CLEAN)은 원본과 같은 그림을 씁니다. " <>
        "estimate_length 로 길이를 확인하세요. 언어마다 글자 수가 달라 길이가 어긋납니다."

  defp instruction("translate_scenes"),
    do:
      "원본의 장면 구성을 그대로 두고 info_instruction 과 expected_labels 만 이 언어로 옮겨 " <>
        "save_scenes 로 저장하세요. shot_prompt·camera_plan·target_sec 은 원본과 같아야 합니다."

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