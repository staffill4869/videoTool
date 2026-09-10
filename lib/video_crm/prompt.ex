defmodule VideoCRM.Prompt do
  @moduledoc """
  프롬프트 조립. 템플릿의 자리표시자를 프리셋·장면 데이터로 치환한다.

  프롬프트가 A4 2~4장이라 매번 통째로 다시 쓰고 있었는데, 실제로 바뀌는 건 일부 절뿐이다.
  그림체를 바꾸면 style 절만, 장르를 바꾸면 domain 절만 갈린다.

  ## 쓸 수 있는 자리표시자

  고정 슬롯:
    {{project.aspect}} {{project.title}} {{project.topic}} {{project.target_sec}}
    {{project.target_chars}} {{voice.display_name}} {{scene_count}} {{script}}
    {{scenes}} {{allowed_facts}}
    {{style.global_style}} {{style.clean_rules}} {{style.camera_rules}} {{style.asset_definitions}}
    {{domain.info_rules}} {{domain.element_list}} {{domain.color_semantics}} {{domain.video_topic_rules}}

  자유 변수:
    {{var.이름}} — 그림체/장르 프리셋의 `variables` 맵에서 가져온다. 이름은 마음대로 정한다.
    값이 없으면 지우지 않고 `⟨미설정: 이름⟩` 으로 남긴다 — 조용히 빈칸이 되면
    말이 안 되는 프롬프트가 Flow 로 들어간다.

  프리셋 텍스트 안에 또 자리표시자를 써도 된다 (치환을 두 번 돈다).
  """

  alias VideoCRM.{Presets, Projects}

  @doc """
  단계별 프롬프트를 완성한다.

  옵션:
    * `:scene_no` — 그 장면 하나짜리 프롬프트 (검증 실패 후 재생성용)
    * `:problems` — 재생성 사유. 프롬프트 맨 위에 붙는다.
  """
  def render(project, stage, opts \\ []) do
    with {:ok, body} <- body_for(project, stage) do
      {:ok, fill(project, stage, body, opts)}
    end
  end

  @doc """
  이 프로젝트가 쓸 본문. 프로젝트 전용 프롬프트가 있으면 그것, 없으면 공용 템플릿.
  한 편만 다르게 가야 할 때가 실제로 생긴다.
  """
  def body_for(project, stage) do
    case Map.get(project.prompt_overrides || %{}, stage) do
      body when is_binary(body) and body != "" -> {:ok, body}
      _ -> with {:ok, t} <- Presets.fetch_template(stage), do: {:ok, t.body}
    end
  end

  @doc "이 프로젝트가 공용 템플릿을 쓰는가, 전용 프롬프트를 쓰는가."
  def overridden?(project, stage) do
    case Map.get(project.prompt_overrides || %{}, stage) do
      body when is_binary(body) and body != "" -> true
      _ -> false
    end
  end

  @doc """
  저장하지 않은 본문으로 결과를 본다. 편집 화면이 쓴다 —
  저장해야만 확인할 수 있으면 프롬프트를 고칠 엄두가 안 난다.
  """
  def preview(project, stage, body, opts \\ []) do
    fill(project, stage, body, opts)
  end

  defp fill(project, stage, body, opts) do
    scenes = select_scenes(project, opts[:scene_no])
    script = Projects.active_script(project.id)
    segments = Projects.segments_by_scene(script && script.id)

    body
    |> replace_all(assigns(project, stage, scenes, segments, script))
    |> replace_variables(variables(project))
    |> prepend_problems(opts[:problems])
  end

  defp select_scenes(project, nil), do: Projects.scenes(project.id)

  defp select_scenes(project, scene_no) do
    project.id |> Projects.scenes() |> Enum.filter(&(&1.scene_no == scene_no))
  end

  defp assigns(project, stage, scenes, segments, script) do
    style = project.style
    domain = project.domain

    %{
      "style.global_style" => style.global_style,
      "style.clean_rules" => style.clean_rules,
      "style.camera_rules" => style.camera_rules,
      "style.asset_definitions" => style.asset_definitions,
      "domain.info_rules" => domain.info_rules,
      "domain.element_list" => domain.element_list,
      "domain.color_semantics" => format_colors(domain.color_semantics),
      "domain.video_topic_rules" => domain.video_topic_rules,
      "project.aspect" => project.aspect,
      "project.title" => project.title,
      "project.topic" => project.topic,
      "project.target_sec" => project.target_sec,
      "project.language" => Projects.language_label(project.language),
      "project.language_code" => project.language,
      "project.target_chars" => round(project.target_sec * project.voice.chars_per_sec),
      "voice.display_name" => project.voice.display_name,
      "scene_count" => Integer.to_string(length(scenes)),
      "scenes" => render_scenes(stage, scenes, segments),
      "allowed_facts" => render_allowed_facts(stage, script),
      "script" => (script && script.raw_text) || "(대본 없음)"
    }
  end

  # 두 번 돈다. 프리셋 텍스트(style.clean_rules 등) 안에 또 자리표시자가 들어 있을 수 있는데,
  # 맵 순회 순서는 보장되지 않아 한 번만 돌면 안쪽 것이 치환 안 된 채 남을 수 있다.
  defp replace_all(body, assigns) do
    Enum.reduce(1..2, body, fn _pass, text ->
      Enum.reduce(assigns, text, fn {key, value}, acc ->
        String.replace(acc, "{{#{key}}}", to_string(value))
      end)
    end)
  end

  @doc """
  `{{var.이름}}` 을 프리셋 변수로 바꾼다.

  고정 자리표시자와 따로 두는 이유: 어떤 칸을 바꿔 끼우고 싶은지는 프롬프트를 고쳐 보면서
  알게 된다. 그때마다 코드를 고쳐야 하면 결국 안 고치게 된다.

  값이 없으면 지우지 않고 `⟨미설정: 이름⟩` 으로 남긴다 — 조용히 빈칸이 되면
  프롬프트가 말이 안 되는 채로 Flow 에 들어간다.
  """
  def replace_variables(text, variables) do
    Regex.replace(~r/\{\{var\.([^}]+)\}\}/u, text, fn _whole, name ->
      key = String.trim(name)

      case Map.get(variables, key) do
        nil -> "⟨미설정: #{key}⟩"
        "" -> "⟨미설정: #{key}⟩"
        value -> to_string(value)
      end
    end)
  end

  @doc "이 프로젝트에서 쓸 수 있는 변수 (장르 위에 그림체를 얹는다 — 그림체가 이긴다)."
  def variables(project) do
    # 기본값 < 장르 < 그림체 < 프로젝트. 뒤가 이긴다.
    # 표기언어는 프로젝트 언어에서 자동으로 채운다 — 언어판을 만들 때마다
    # 변수를 손으로 고치게 하면 반드시 빠뜨린다.
    %{"표기언어" => Projects.language_label(project.language)}
    |> Map.merge(project.domain.variables || %{})
    |> Map.merge(project.style.variables || %{})
    |> Map.merge(project.variables || %{})
  end

  @doc "프롬프트가 쓰는데 값이 없는 변수 이름들. 화면에서 경고로 띄운다."
  def missing_variables(project, stage) do
    with {:ok, body} <- body_for(project, stage) do
      available = variables(project)

      names =
        ~r/\{\{var\.([^}]+)\}\}/u
        |> Regex.scan(body)
        |> Enum.map(fn [_, name] -> String.trim(name) end)
        |> Enum.uniq()

      {:ok, Enum.reject(names, &(Map.get(available, &1) not in [nil, ""]))}
    end
  end

  defp prepend_problems(body, nil), do: body
  defp prepend_problems(body, []), do: body

  defp prepend_problems(body, problems) do
    lines =
      Enum.map_join(problems, "\n", fn p ->
        "- #{p["scene_no"]}번: #{p["issue"]}"
      end)

    """
    아래 컷만 다시 생성한다. 지적된 문제를 반드시 고칠 것.
    #{lines}

    #{body}
    """
  end

  defp format_colors(map) when map_size(map) == 0, do: "(지정 없음)"

  defp format_colors(map),
    do: Enum.map_join(map, ", ", fn {k, v} -> "#{k}=#{v}" end)

  # ── {{scenes}} 렌더링 — 단계마다 형태가 다르다 ──────────────────

  defp render_scenes("clean", scenes, _segments) do
    Enum.map_join(scenes, "\n\n", fn s ->
      """
      === IMAGE #{pad(s.scene_no)} / #{filename(s)} / #{fmt(s.target_sec)}s ===
      #{s.shot_prompt}
      Apply the GLOBAL STYLE above. No text, numbers, arrows, labels, icons or route lines.
      """
      |> String.trim()
    end)
  end

  defp render_scenes("info", scenes, _segments) do
    Enum.map_join(scenes, "\n", fn s ->
      "#{s.scene_no}번 이미지 (요약): #{s.info_instruction}"
    end)
  end

  defp render_scenes("video", scenes, segments) do
    Enum.map_join(scenes, "\n\n", fn s ->
      plan = s.camera_plan || %{}

      """
      --- 장면 #{pad(s.scene_no)} (#{fmt(s.target_sec)}s, #{s.purpose}) ---
      대본 구간: #{Map.get(segments, s.id, "(없음)")}
      카메라: 초반 #{Map.get(plan, "early", "-")} / 중반 #{Map.get(plan, "mid", "-")} / 후반 #{Map.get(plan, "late", "-")}
      절개 여부: #{Map.get(plan, "cutaway", "없음")}
      빠른 줌: #{if s.use_fast_zoom, do: "사용", else: "사용 안 함"}
      인포그래픽 등장 순서: #{labels(s)}
      생성 프롬프트: #{s.shot_prompt}
      """
      |> String.trim()
    end)
  end

  defp render_scenes(_stage, scenes, _segments) do
    Enum.map_join(scenes, "\n", fn s -> "#{s.scene_no}. #{s.shot_prompt}" end)
  end

  defp labels(%{expected_labels: []}), do: "(없음)"
  defp labels(%{expected_labels: labels}), do: Enum.join(labels, " → ")

  defp filename(scene), do: "S#{pad(scene.scene_no)}.png"
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
  defp fmt(nil), do: "0.0"
  defp fmt(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 1)
  defp fmt(n), do: to_string(n)

  # ── {{allowed_facts}} — INFO 단계에서만 주입한다 ────────────────

  defp render_allowed_facts(stage, script) when stage != "info" or is_nil(script), do: ""

  defp render_allowed_facts(_stage, script) do
    facts = Projects.allowed_facts(script.id)
    {numbers, names} = Enum.split_with(facts, &(&1.kind == "number"))

    """
    아래 목록에 있는 수치와 명칭만 사용하라.
    허용 수치: #{join_values(numbers)}
    허용 명칭: #{join_values(names)}
    이 목록에 없는 숫자, 병력 수, 날짜, 지명, 인명은 절대 넣지 말라.
    """
    |> String.trim()
  end

  defp join_values([]), do: "(없음)"
  defp join_values(facts), do: Enum.map_join(facts, ", ", & &1.value)
end