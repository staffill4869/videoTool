defmodule VideoTool.Prompt do
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

  alias VideoTool.{Presets, Projects}

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

  # 한 번에 다 보내면 Flow 가 통째로 실패한다(16장 요청 → 전부 거부, 요금 미청구).
  # 그래서 장면 번호 묶음으로도 렌더할 수 있어야 한다.
  defp select_scenes(project, scene_nos) when is_list(scene_nos) do
    project.id |> Projects.scenes() |> Enum.filter(&(&1.scene_no in scene_nos))
  end

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
      # 화면비 숫자만으로는 생성기가 구도를 못 잡는다. "9:16 가로형" 같은 모순을 막으려면
      # 방향을 말로 붙여야 한다 — 실제로 그렇게 나가고 있었다.
      "project.orientation" => orientation(project.aspect, en?(project)),
      "scenes" => render_scenes(stage, scenes, segments, project.aspect || "16:9", en?(project)),
      "allowed_facts" => render_allowed_facts(stage, script, en?(project)),
      "character" => character(project),
      "script" => (script && script.raw_text) || "(대본 없음)"
    }
  end

  # 고정 캐릭터 설명. **프롬프트 본문에 직접** 넣는다.
  #
  # 예전엔 Flow 상시 지시(요청 사항)에만 넣었다. 그런데 2026-09-18 Flow 화면이 바뀐 뒤로
  # 상시 지시가 이미지 생성에 적용되지 않아, 장면 지시의 "Momo" 라는 이름만 보고 생성기가
  # 고양이를 지어냈다 — 회색 고등어 줄무늬 대신 주황 고양이 7장에 삼색이 1장이 나왔다.
  # 요청마다 따라가는 본문에 두면 상시 지시가 되든 안 되든 상관없다.
  defp character(project) do
    en = get_in(project.variables || %{}, ["standing_en"])

    cond do
      en?(project) and is_binary(en) and en != "" ->
        en

      project.series_id ->
        case VideoTool.Series.get(project.series_id) do
          {:ok, %{standing_prompt: s}} when is_binary(s) and s != "" -> s
          _ -> ""
        end

      true ->
        ""
    end
  end

  @doc """
  Flow 에 보내는 프롬프트를 영어로 쓸 것인가. 나레이션·자막 언어(`project.language`)와 **별개**다.

  Flow(Imagen·Veo)는 영어가 모국어인 모델이다. 한국어 프롬프트가 조용한 오해석의 원인인지
  보려고 만든 스위치다 — 나레이션은 한국어로 두고 그림 지시만 영어로 바꿔 한 변수만 비교한다.
  템플릿 본문은 `prompt_overrides` 로 갈아끼우고, 여기서는 **렌더러가 박아 넣는 머리말**
  ("N번 이미지", "대본 구간", "허용 수치" …)을 영어로 바꾼다. 안 바꾸면 영어 본문에
  한국어가 섞여 실험이 안 된다.
  """
  def en?(project), do: get_in(project.variables || %{}, ["prompt_lang"]) == "en"

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

  defp orientation(aspect, true), do: aspect_words(aspect)
  defp orientation("9:16", _), do: "세로형. 인물과 핵심 대상을 화면 가운데 세로축에 두고, 좌우는 비운다"
  defp orientation("16:9", _), do: "가로형. 좌우로 넓게 쓰고, 여백은 한쪽에 몰아 둔다"
  defp orientation(_, _), do: "가로형"

  # ── {{scenes}} 렌더링 — 단계마다 형태가 다르다 ──────────────────

  # 화면비를 장면마다 붙인다. 맨 위에 한 번만 적으면 에이전트가 흘린다.
  # 같은 말을 반복하는 건 낭비가 아니라, 한 번 흘려도 다음에서 잡히게 하는 장치다.
  # 영어판 INFO·VIDEO. CLEAN 은 원래부터 영어라 따로 없다.
  # VIDEO 에서 "대본 구간" 은 뺀다 — 나레이션은 한국어라 그대로 넣으면 영어 프롬프트에
  # 한국어가 섞인다. 화면에 필요한 건 shot_prompt 와 카메라 계획에 이미 다 있다.
  # 원본을 **번호가 아니라 그림 내용과 ID 로** 가리킨다 (source_hint, media_ref 참고).
  defp render_scenes("info", scenes, _segments, _aspect, true) do
    Enum.map_join(scenes, "\n\n", fn s ->
      "Image #{s.scene_no}\n  Edit the source image#{id_en(media_ref(s, "clean"))} that shows: #{s.shot_prompt}\n  Add: #{s.info_instruction}"
    end)
  end

  defp render_scenes("video", scenes, _segments, _aspect, true) do
    Enum.map_join(scenes, "\n\n", fn s ->
      plan = s.camera_plan || %{}

      """
      --- SCENE #{pad(s.scene_no)} (#{fmt(s.target_sec)}s, #{s.purpose}) ---
      #{frames_en(s)}
      Camera: early #{Map.get(plan, "early", "-")} / mid #{Map.get(plan, "mid", "-")} / late #{Map.get(plan, "late", "-")}
      Cutaway: #{Map.get(plan, "cutaway", "none")}
      Fast zoom: #{if s.use_fast_zoom, do: "yes", else: "no"}
      Graphic build order: #{labels_en(s)}
      Shot: #{s.shot_prompt}
      """
      |> String.trim()
    end)
  end

  defp render_scenes(stage, scenes, segments, aspect, _en), do: render_scenes(stage, scenes, segments, aspect)

  # Flow 에이전트는 프로젝트 안의 그림을 UUID 로 부른다 — 실측(62번): "Using the provided reference
  # image (49d94def-…) as a base". 회수할 때 source_filename 에 남긴 게 바로 그 UUID 다.
  # 이걸 적어 주면 "N번" 이나 생성 순서에 기대지 않고 원본·짝을 정확히 집는다.
  # 순서에 기대면 장면 하나만 다시 만든 뒤 에이전트가 가장 최근 그림으로 전부 그렸다.
  defp media_ref(scene, kind) do
    VideoTool.Media.list_assets(scene.project_id, kind)
    |> Enum.filter(&(&1.scene_id == scene.id and &1.status != "rejected"))
    |> Enum.max_by(& &1.order_confidence, fn -> nil end)
    |> case do
      %{source_filename: id} when is_binary(id) ->
        if Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, id), do: id

      _ ->
        nil
    end
  end

  defp id_en(nil), do: ""
  defp id_en(id), do: " (image id #{id})"

  defp id_ko(nil), do: ""
  defp id_ko(id), do: " (이미지 id #{id})"

  defp frames_en(s) do
    case {media_ref(s, "clean"), media_ref(s, "info")} do
      {nil, nil} -> "Frames: find this scene's start and end images by what they show."
      {c, i} -> "Start frame: image id #{c || "(find by content)"}\nEnd frame: image id #{i || "(find by content)"}"
    end
  end

  defp frames_ko(s) do
    case {media_ref(s, "clean"), media_ref(s, "info")} do
      {nil, nil} -> ""
      {c, i} -> "시작 프레임: 이미지 id #{c || "(내용으로 찾기)"}\n끝 프레임: 이미지 id #{i || "(내용으로 찾기)"}\n"
    end
  end

  defp labels_en(%{expected_labels: []}), do: "(none)"
  defp labels_en(%{expected_labels: labels}), do: Enum.join(labels, " -> ")

  defp render_scenes("clean", scenes, _segments, aspect) do
    Enum.map_join(scenes, "

", fn s ->
      """
      === IMAGE #{pad(s.scene_no)} / #{filename(s)} / #{fmt(s.target_sec)}s / #{aspect} ===
      #{s.shot_prompt}
      Apply the GLOBAL STYLE above. No text, numbers, arrows, labels, icons or route lines.
      Aspect ratio: #{aspect}. #{aspect_words(aspect)}
      """
      |> String.trim()
    end)
  end
  # source_hint: INFO 는 "N번 이미지" 라는 번호만으로는 원본을 못 찾는다. CLEAN 을 한 번에 다
  # 만들었을 때만 순서가 맞는다 — 62번에서 1번 장면만 다시 만들었더니 Flow 가 가장 최근 그림(1번)
  # 하나로 네 장을 전부 새로 그렸다 (배경·머리 모양이 모두 1번 것). 장면 하나 재생성은 무인 루프에서도
  # 생기므로, 각 원본을 그림 내용(shot_prompt)으로 지목한다.
  defp render_scenes("info", scenes, _segments, _aspect) do
    Enum.map_join(scenes, "\n\n", fn s ->
      "#{s.scene_no}번 이미지\n  편집할 원본#{id_ko(media_ref(s, "clean"))}: 이 장면을 담은 이미지 — #{s.shot_prompt}\n  추가할 것: #{s.info_instruction}"
    end)
  end

  defp render_scenes("video", scenes, segments, _aspect) do
    Enum.map_join(scenes, "\n\n", fn s ->
      plan = s.camera_plan || %{}

      """
      --- 장면 #{pad(s.scene_no)} (#{fmt(s.target_sec)}s, #{s.purpose}) ---
      #{frames_ko(s)}대본 구간: #{Map.get(segments, s.id, "(없음)")}
      카메라: 초반 #{Map.get(plan, "early", "-")} / 중반 #{Map.get(plan, "mid", "-")} / 후반 #{Map.get(plan, "late", "-")}
      절개 여부: #{Map.get(plan, "cutaway", "없음")}
      빠른 줌: #{if s.use_fast_zoom, do: "사용", else: "사용 안 함"}
      인포그래픽 등장 순서: #{labels(s)}
      생성 프롬프트: #{s.shot_prompt}
      """
      |> String.trim()
    end)
  end

  defp render_scenes(_stage, scenes, _segments, _aspect) do
    Enum.map_join(scenes, "\n", fn s -> "#{s.scene_no}. #{s.shot_prompt}" end)
  end

  defp aspect_words("9:16"),
    do: "MUST be vertical portrait, taller than wide. Do NOT produce a landscape image."

  defp aspect_words("16:9"),
    do: "MUST be horizontal landscape, wider than tall. Do NOT produce a vertical image."

  defp aspect_words(_), do: ""

  defp labels(%{expected_labels: []}), do: "(없음)"
  defp labels(%{expected_labels: labels}), do: Enum.join(labels, " → ")

  defp filename(scene), do: "S#{pad(scene.scene_no)}.png"
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
  defp fmt(nil), do: "0.0"
  defp fmt(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 1)
  defp fmt(n), do: to_string(n)

  # ── {{allowed_facts}} — INFO 단계에서만 주입한다 ────────────────

  defp render_allowed_facts(stage, script, _en) when stage != "info" or is_nil(script), do: ""

  defp render_allowed_facts(_stage, script, true) do
    {numbers, names} = script.id |> Projects.allowed_facts() |> Enum.split_with(&(&1.kind == "number"))

    """
    Only these numbers and names may appear. Nothing outside this list.
    Allowed numbers: #{join_values(numbers, "(none)")}
    Allowed names: #{join_values(names, "(none)")}
    Never invent any other number, date, place or person.
    """
    |> String.trim()
  end

  defp render_allowed_facts(_stage, script, _en) do
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

  defp join_values(facts, empty \\ "(없음)")
  defp join_values([], empty), do: empty
  defp join_values(facts, _empty), do: Enum.map_join(facts, ", ", & &1.value)
end