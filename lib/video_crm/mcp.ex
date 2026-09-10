defmodule VideoCRM.MCP do
  @moduledoc """
  MCP 툴 정의와 디스패치.

  이 서버에는 LLM 이 없다. 창작(대본·장면·SHOT 문장·허용 수치)은 에이전트가 하고
  여기서는 저장·조립·클립보드 주입·검증 같은 기계적인 일만 한다.

  아직 구현되지 않은 단계는 성공한 척하지 않고 `ok: false` 로 명시적으로 실패한다.
  """

  alias VideoCRM.{Flow, Ingest, Jobs, Media, Pipeline, Projects, Prompt, Publishing, Presets, Series, Work, Insights}

  # Flow Ultra 기준. 사용자가 화면에서 읽은 값으로 갱신할 수 있다.
  @krw_per_flow_credit 13.7

  # ── 툴 목록 ─────────────────────────────────────────────────────

  def tools do
    [
      tool("list_presets", "그림체·장르·보이스·템플릿 프리셋 목록", %{
        "kind" => str("style | domain | voice | template. 생략하면 전부")
      }),
      tool(
        "create_project",
        "프로젝트를 만든다. 프리셋은 slug 로 참조한다",
        %{
          "title" => str("영상 제목"),
          "topic" => str("주제"),
          "target_sec" => int("목표 길이(초)"),
          "aspect" => str("16:9 또는 9:16. 생략하면 그림체 기본값"),
          "style_slug" => str("그림체 slug"),
          "domain_slug" => str("장르 slug"),
          "voice_slug" => str("보이스 slug"),
          "output_folder" => str("완성본을 놓을 사용자 폴더")
        },
        ["title", "style_slug", "domain_slug", "voice_slug"]
      ),
      tool(
        "estimate_length",
        "대본 길이를 초로 계산한다. 대본을 쓰기 전·후에 반드시 부를 것",
        %{"voice_slug" => str("보이스 slug"), "text" => str("대본 원문")},
        ["voice_slug", "text"]
      ),
      tool(
        "save_script",
        "대본을 새 버전으로 저장한다. 이전 버전은 비활성화된다",
        %{
          "project_id" => int("프로젝트 id"),
          "raw_text" => str("원문 그대로. 문체를 보존한다"),
          "tts_text" => str("TTS 용 정제본. 생략하면 raw_text 를 쓴다"),
          "source" => str("draft | revised | screen_matched")
        },
        ["project_id", "raw_text"]
      ),
      tool(
        "save_scenes",
        "장면 분할을 저장한다. scene_no 기준 upsert 라 이미 붙은 이미지 연결이 유지된다",
        %{
          "project_id" => int("프로젝트 id"),
          "scenes" => %{
            "type" => "array",
            "description" =>
              "각 원소: scene_no, target_sec, purpose(hook|setup|turn|payoff|close), " <>
                "segment_text, shot_prompt, info_instruction, camera_plan{early,mid,late}, " <>
                "use_fast_zoom, expected_labels[]",
            "items" => %{"type" => "object"}
          }
        },
        ["project_id", "scenes"]
      ),
      tool(
        "save_allowed_facts",
        "허용 수치·명칭 화이트리스트. 이게 없으면 INFO 단계에서 없는 숫자가 렌더링된다",
        %{
          "project_id" => int("프로젝트 id"),
          "facts" => %{
            "type" => "array",
            "description" => "각 원소: kind(number|place|person|date), value, note",
            "items" => %{"type" => "object"}
          }
        },
        ["project_id", "facts"]
      ),
      tool("next", "다음에 할 일을 정하고 필요하면 프롬프트를 클립보드에 넣는다", %{
        "project_id" => int("프로젝트 id")
      }, ["project_id"]),
      tool("status", "프로젝트 현재 상태", %{"project_id" => int("프로젝트 id")}, ["project_id"]),
      tool(
        "render_prompt",
        "클립보드에 넣지 않고 프롬프트 텍스트만 돌려준다",
        %{
          "project_id" => int("프로젝트 id"),
          "stage" => str("clean | info | video"),
          "scene_no" => int("주면 그 장면 하나만")
        },
        ["project_id", "stage"]
      ),
      tool(
        "report_flow_credits",
        "Flow 는 API 가 없어 화면에서 읽은 크레딧을 수동 입력한다",
        %{"project_id" => int("프로젝트 id"), "credits" => num("크레딧")},
        ["project_id", "credits"]
      ),
      tool("cost_report", "프로젝트 비용 집계", %{"project_id" => int("프로젝트 id")}, ["project_id"]),
      tool("list_channels", "발행 대상 채널과 토큰 상태", %{}),
      tool(
        "save_publish_meta",
        "제목·설명·해시태그를 저장만 한다. 발행하지 않는다",
        %{
          "project_id" => int("프로젝트 id"),
          "channel_slug" => str("채널 slug"),
          "title" => str("제목"),
          "description" => str("설명"),
          "hashtags" => %{"type" => "array", "items" => %{"type" => "string"}},
          "privacy" => str("private | unlisted | public"),
          "scheduled_at" => str("ISO8601 예약 시각")
        },
        ["project_id", "channel_slug", "title"]
      ),
      tool(
        "publish",
        "발행한다. confirm 이 true 가 아니면 실행하지 않는다. " <>
          "사용자가 발행을 지시했을 때만 confirm: true 를 넣을 것",
        %{
          "project_id" => int("프로젝트 id"),
          "channel_slug" => str("채널 slug"),
          "confirm" => %{"type" => "boolean", "description" => "사용자 지시가 있을 때만 true"}
        },
        ["project_id", "channel_slug", "confirm"]
      ),
      tool("ingest", "Downloads 의 Flow zip 을 가져와 장면에 매핑한다 (3주차)", %{
        "project_id" => int("프로젝트 id"),
        "path" => str("생략하면 Downloads 에서 최신 zip 을 찾는다")
      }, ["project_id"]),
      tool("generate_narration", "TTS · 무음 정렬 · 자막 생성 (4주차)", %{
        "project_id" => int("프로젝트 id")
      }, ["project_id"]),
      tool("assemble", "클립 리타이밍 + 합성 (4주차)", %{"project_id" => int("프로젝트 id")}, [
        "project_id"
      ]),
      tool("make_vertical", "가로 완성본에서 9:16 세로본 생성 (4주차)", %{
        "project_id" => int("프로젝트 id")
      }, ["project_id"]),
      tool(
        "flow_status",
        "Flow 브라우저 자동 조종이 가능한 상태인지 확인한다 (Chrome 연결 · Flow 탭 · 로그인)",
        %{}
      ),
      tool(
        "next_job",
        "다음에 할 일 하나를 받는다. **연결돼 있는 동안 이것만 반복해 부르면 여러 프로젝트를 이어서 처리한다.** " <>
          "에이전트만 할 수 있는 일(대본·장면분할·허용수치)만 내준다",
        %{}
      ),
      tool("work_summary", "대기 중인 일이 몇 건인지, 시리즈가 몇 개 도는지", %{}),
      tool("list_series", "반복 제작 설정 목록", %{}),
      tool(
        "run_series",
        "시리즈로 프로젝트를 지금 하나 만든다 (간격을 기다리지 않고)",
        %{
          "series_id" => int("시리즈 id"),
          "topic" => str("이번 편 주제. 생략하면 시리즈 기본 주제")
        },
        ["series_id"]
      ),
      tool(
        "create_language_variant",
        "같은 영상의 다른 언어판을 만든다. CLEAN 이미지는 다시 만들지 않고 원본 것을 그대로 쓴다 " <>
          "(글자가 없어서 언어와 무관하다). INFO 와 나레이션만 새로 만들면 된다",
        %{
          "project_id" => int("원본 프로젝트 id"),
          "language" => str("ko | en | ja | zh | es | ... (list_languages 참고)"),
          "voice_slug" => str("그 언어용 보이스. 생략하면 원본과 같은 보이스"),
          "title" => str("제목. 생략하면 원본 제목 + [언어]")
        },
        ["project_id", "language"]
      ),
      tool("list_languages", "쓸 수 있는 언어 코드", %{}),
      tool("dashboard", "조회수·좋아요·댓글 집계 (채널별·언어별·영상별)", %{}),
      tool(
        "collect_metrics",
        "유튜브에서 조회수·좋아요·댓글을 긁어와 기록한다. API 키만 있으면 되고 업로드용 OAuth 는 필요 없다",
        %{}
      ),
      tool(
        "record_metrics",
        "발행물의 성과를 기록한다. 잴 때마다 새로 쌓이므로 증가 추이가 남는다",
        %{
          "publication_id" => int("발행물 id"),
          "views" => int("조회수"),
          "likes" => int("좋아요"),
          "comments" => int("댓글"),
          "shares" => int("공유"),
          "note" => str("메모")
        },
        ["publication_id"]
      ),
      tool(
        "register_published",
        "이 시스템 밖에서 이미 올린 영상을 등록한다. 등록해야 성과를 집계할 수 있다",
        %{
          "project_id" => int("프로젝트 id"),
          "channel_slug" => str("채널 slug"),
          "external_url" => str("영상 URL"),
          "external_id" => str("플랫폼 id (유튜브 videoId 등)"),
          "title" => str("제목. 생략하면 프로젝트 제목")
        },
        ["project_id", "channel_slug"]
      ),
      tool(
        "set_prompt_override",
        "이 프로젝트에서만 쓸 프롬프트를 저장한다. body 를 비우면 공용 템플릿으로 돌아간다",
        %{
          "project_id" => int("프로젝트 id"),
          "stage" => str("clean | info | video"),
          "body" => str("프롬프트 본문. 비우면 오버라이드 해제")
        },
        ["project_id", "stage"]
      ),
      tool(
        "set_pipeline",
        "프로젝트의 생성 경로를 바꾼다. ai=사람이 Flow 조작, flow_auto=브라우저 자동 조종",
        %{
          "project_id" => int("프로젝트 id"),
          "pipeline" => str("ai | flow_auto")
        },
        ["project_id", "pipeline"]
      )
    ]
  end

  defp tool(name, description, properties, required \\ []) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{
        "type" => "object",
        "properties" => properties,
        "required" => required
      }
    }
  end

  defp str(desc), do: %{"type" => "string", "description" => desc}
  defp int(desc), do: %{"type" => "integer", "description" => desc}
  defp num(desc), do: %{"type" => "number", "description" => desc}

  # ── 디스패치 ────────────────────────────────────────────────────

  def call(name, args) do
    handle(name, args || %{})
  rescue
    e -> %{ok: false, error: "#{name} 실행 중 오류: #{Exception.message(e)}"}
  end

  defp handle("list_presets", args) do
    kind = args["kind"]

    %{ok: true}
    |> maybe_put(kind in [nil, "style"], :styles, fn ->
      Enum.map(Presets.list_styles(), &%{slug: &1.slug, name: &1.name, aspect: &1.default_aspect})
    end)
    |> maybe_put(kind in [nil, "domain"], :domains, fn ->
      Enum.map(Presets.list_domains(), &%{slug: &1.slug, name: &1.name})
    end)
    |> maybe_put(kind in [nil, "voice"], :voices, fn ->
      Enum.map(
        Presets.list_voices(),
        &%{
          slug: &1.slug,
          display_name: &1.display_name,
          chars_per_sec: Float.round(&1.chars_per_sec, 2),
          sample_count: &1.sample_count
        }
      )
    end)
    |> maybe_put(kind in [nil, "template"], :templates, fn ->
      Enum.map(Presets.list_templates(), &%{stage: &1.stage, version: &1.version, notes: &1.notes})
    end)
  end

  defp handle("create_project", args) do
    case Projects.create_project(args) do
      {:ok, project} ->
        %{ok: true, project_id: project.id, work_dir: project.work_dir, status: project.status}

      {:error, %Ecto.Changeset{} = cs} ->
        %{ok: false, error: changeset_error(cs)}

      {:error, reason} ->
        %{ok: false, error: reason}
    end
  end

  defp handle("estimate_length", args) do
    with {:ok, voice} <- Presets.fetch_voice(args["voice_slug"]) do
      est = Projects.estimate_length(voice, args["text"])
      Map.merge(%{ok: true}, est)
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  defp handle("save_script", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]),
         {:ok, script, est} <-
           Projects.save_script(project, args["raw_text"], args["tts_text"], args["source"]) do
      delta = est.estimated_sec - project.target_sec

      %{
        ok: true,
        script_id: script.id,
        version: script.version,
        chars: est.chars,
        estimated_sec: est.estimated_sec,
        target_sec: project.target_sec,
        delta_sec: Float.round(delta, 1),
        advice: length_advice(delta, project, est)
      }
    else
      {:error, %Ecto.Changeset{} = cs} -> %{ok: false, error: changeset_error(cs)}
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  defp handle("save_scenes", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]),
         {:ok, result} <- Projects.save_scenes(project, args["scenes"]) do
      %{
        ok: true,
        created: result.created,
        updated: result.updated,
        total_target_sec: Float.round(result.total_target_sec, 1)
      }
    else
      {:error, %Ecto.Changeset{} = cs} -> %{ok: false, error: changeset_error(cs)}
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  defp handle("save_allowed_facts", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]),
         script when not is_nil(script) <- Projects.active_script(project.id),
         {:ok, count} <- Projects.save_allowed_facts(script, args["facts"]) do
      %{ok: true, saved: count, script_version: script.version}
    else
      nil -> %{ok: false, error: "활성 대본이 없습니다. save_script() 를 먼저 부르세요"}
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("next", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]) do
      Map.merge(%{ok: true}, Pipeline.next(project))
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  defp handle("status", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]) do
      narration = Media.latest_narration(project.id)
      validation = Jobs.latest_validation(project.id)

      %{
        ok: true,
        project_id: project.id,
        title: project.title,
        status: project.status,
        aspect: project.aspect,
        scenes: length(Projects.scenes(project.id)),
        assets: Media.asset_counts(project.id),
        mapped: Media.mapped_counts(project.id),
        narration: narration && %{duration_sec: narration.duration_sec},
        last_validation:
          validation && %{stage: validation.stage, passed: validation.passed},
        credits: Jobs.credits_by_provider(project.id),
        work_dir: project.work_dir,
        output_folder: project.output_folder
      }
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  defp handle("render_prompt", args) do
    opts = if args["scene_no"], do: [scene_no: args["scene_no"]], else: []

    with {:ok, project} <- Projects.get_project(args["project_id"]),
         {:ok, text} <- Prompt.render(project, args["stage"], opts) do
      %{ok: true, stage: args["stage"], text: text, chars: String.length(text)}
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  defp handle("report_flow_credits", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]),
         {:ok, _job} <- Jobs.report_flow_credits(project.id, args["credits"]) do
      %{ok: true, credits: Jobs.credits_by_provider(project.id)}
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("cost_report", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]) do
      credits = Jobs.credits_by_provider(project.id)
      flow = Map.get(credits, "flow", 0.0)
      total = credits |> Map.values() |> Enum.sum()

      %{
        ok: true,
        by_provider: credits,
        total: Float.round(total, 2),
        krw_estimate: round(flow * @krw_per_flow_credit),
        note: "Flow Ultra 기준 크레딧당 약 #{@krw_per_flow_credit}원. 힉스필드는 환산에서 제외"
      }
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  defp handle("list_channels", _args) do
    channels =
      Enum.map(Publishing.list_channels(), fn c ->
        valid = Publishing.Channel.token_valid?(c)

        %{
          slug: c.slug,
          platform: c.platform,
          display_name: c.display_name,
          aspect_required: c.aspect_required,
          max_duration_sec: c.max_duration_sec,
          token_valid: valid,
          warning: if(valid, do: nil, else: "토큰 없음/만료. reauth('#{c.slug}') 필요")
        }
      end)

    %{ok: true, channels: channels}
  end

  defp handle("save_publish_meta", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]),
         {:ok, channel} <- Publishing.fetch_channel(args["channel_slug"]),
         render when not is_nil(render) <- Publishing.render_for(project.id, channel),
         {:ok, publication, warnings} <-
           Publishing.save_publish_meta(project, channel, render, args) do
      %{
        ok: true,
        publication_id: publication.id,
        status: publication.status,
        render_id: render.id,
        warnings: warnings
      }
    else
      nil ->
        %{ok: false, error: "이 채널이 요구하는 화면비의 완성본이 아직 없습니다"}

      {:error, %Ecto.Changeset{} = cs} ->
        %{ok: false, error: changeset_error(cs)}

      {:error, reason} ->
        %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("publish", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]),
         {:ok, channel} <- Publishing.fetch_channel(args["channel_slug"]),
         render when not is_nil(render) <- Publishing.render_for(project.id, channel) do
      # publish/4 는 아직 {:error, _} 만 돌려준다. 업로드가 붙으면 {:ok, _} 절을 여기 추가한다.
      case Publishing.publish(project, channel, render, args["confirm"]) do
        {:error, reasons} when is_list(reasons) -> %{ok: false, error: Enum.join(reasons, " / ")}
        {:error, reason} -> %{ok: false, error: reason}
      end
    else
      nil -> %{ok: false, error: "이 채널이 요구하는 화면비의 완성본이 아직 없습니다"}
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("ingest", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]),
         {:ok, summary} <- Ingest.run(project, args["path"]) do
      Map.merge(%{ok: true}, summary)
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("next_job", _args) do
    {:ok, job} = Work.next_job()

    case job do
      nil -> %{ok: true, job: nil, message: "지금 할 일이 없습니다."}
      job -> Map.merge(%{ok: true}, job)
    end
  end

  defp handle("work_summary", _args), do: Map.merge(%{ok: true}, Work.summary())

  defp handle("list_series", _args) do
    series =
      Enum.map(Series.list(), fn s ->
        %{
          id: s.id,
          name: s.name,
          active: s.active,
          interval_minutes: s.interval_minutes,
          languages: s.languages,
          created_count: s.created_count,
          pending: Series.pending_count(s.id),
          next_run_at: s.next_run_at,
          last_error: s.last_error
        }
      end)

    %{ok: true, series: series}
  end

  defp handle("run_series", args) do
    with {:ok, series} <- Series.get(args["series_id"]),
         {:ok, project} <- Series.spawn_project(series, topic: args["topic"]) do
      %{ok: true, project_id: project.id, title: project.title, status: project.status}
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("create_language_variant", args) do
    with {:ok, source} <- Projects.get_project(args["project_id"]),
         {:ok, result} <-
           Projects.create_language_variant(source, args["language"],
             voice_slug: args["voice_slug"],
             title: args["title"]
           ) do
      %{
        ok: true,
        project_id: result.project.id,
        language: result.project.language,
        scenes: result.scenes,
        clean_reused: result.clean_reused,
        next: "INFO 프롬프트부터 시작합니다. CLEAN 은 원본 것을 그대로 씁니다."
      }
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("list_languages", _args), do: %{ok: true, languages: Projects.language_names()}

  defp handle("dashboard", _args) do
    d = Insights.dashboard()

    %{
      ok: true,
      totals: d.totals,
      by_channel: d.by_channel,
      by_language: d.by_language,
      by_project: d.by_project,
      measured: d.measured,
      note:
        if(d.measured == 0,
          do: "측정된 발행물이 없습니다. register_published 로 올린 영상을 먼저 등록하세요.",
          else: nil
        )
    }
  end

  defp handle("collect_metrics", _args) do
    case Insights.collect_youtube() do
      {:ok, result} ->
        Map.merge(%{ok: true}, result)
        |> Map.put(
          :note,
          if(result.missing != [],
            do: "#{length(result.missing)}건은 응답에 없습니다 — 비공개이거나 삭제된 영상입니다.",
            else: nil
          )
        )

      {:error, reason} ->
        %{ok: false, error: reason}
    end
  end

  defp handle("record_metrics", args) do
    attrs = Map.take(args, ~w(views likes comments shares note))

    case Insights.record(args["publication_id"], attrs) do
      {:ok, metric} -> %{ok: true, metric_id: metric.id, collected_at: metric.collected_at}
      {:error, changeset} -> %{ok: false, error: changeset_error(changeset)}
    end
  end

  defp handle("register_published", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]),
         {:ok, channel} <- Publishing.fetch_channel(args["channel_slug"]) do
      render = Media.latest_render(project.id, project.aspect)

      case Insights.register_published(project, channel, render, args) do
        {:ok, pub} -> %{ok: true, publication_id: pub.id, status: pub.status}
        {:error, changeset} -> %{ok: false, error: changeset_error(changeset)}
      end
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("set_prompt_override", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]),
         {:ok, updated} <- Projects.set_prompt_override(project, args["stage"], args["body"]) do
      %{
        ok: true,
        stage: args["stage"],
        overridden: Prompt.overridden?(updated, args["stage"])
      }
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("flow_status", _args) do
    case Flow.status() do
      {:ok, status} ->
        ready = status[:flow_tab] == true and status[:prompt_box] == true

        Map.merge(%{ok: true, ready: ready}, status)
        |> Map.put(
          :next_step,
          cond do
            ready -> "준비됐습니다. set_pipeline(pipeline: \"flow_auto\") 로 켜세요."
            status[:flow_tab] != true -> "Chrome 에서 Flow 탭을 열어두세요."
            true -> "Flow 에 구글 로그인이 필요합니다. 사람이 직접 로그인하세요."
          end
        )

      {:error, reason} ->
        %{
          ok: false,
          ready: false,
          error: reason,
          next_step: "launch-chrome.ps1 을 실행해 디버그 포트로 Chrome 을 띄우세요."
        }
    end
  end

  defp handle("set_pipeline", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]),
         {:ok, updated} <- Projects.set_pipeline(project, args["pipeline"]) do
      %{ok: true, project_id: updated.id, pipeline: updated.pipeline}
    else
      {:error, %Ecto.Changeset{} = cs} -> %{ok: false, error: changeset_error(cs)}
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle(name, _args) when name in ~w(generate_narration assemble make_vertical) do
    %{ok: false, error: not_implemented(name)}
  end

  defp handle(name, _args), do: %{ok: false, error: "알 수 없는 툴: #{name}"}


  defp not_implemented("generate_narration"),
    do: "generate_narration 은 아직 구현되지 않았습니다 (설명서 4주차 — 힉스필드 TTS · 무음 정렬 · 자막)"

  defp not_implemented("assemble"),
    do: "assemble 은 아직 구현되지 않았습니다 (설명서 4주차 — 리타이밍 · ffmpeg 합성)"

  defp not_implemented("make_vertical"),
    do: "make_vertical 은 아직 구현되지 않았습니다 (설명서 4주차 — 블러 배경 9:16 변환)"

  # ── 도우미 ──────────────────────────────────────────────────────

  defp maybe_put(map, false, _key, _fun), do: map
  defp maybe_put(map, true, key, fun), do: Map.put(map, key, fun.())

  defp length_advice(delta, project, est) when delta > 3 do
    target_chars = round(project.target_sec * est.chars_per_sec)
    "#{project.target_sec}초에 맞추려면 약 #{target_chars}자로 줄이세요 (현재 #{est.chars}자)"
  end

  defp length_advice(delta, project, est) when delta < -3 do
    target_chars = round(project.target_sec * est.chars_per_sec)
    "#{project.target_sec}초를 채우려면 약 #{target_chars}자가 필요합니다 (현재 #{est.chars}자)"
  end

  defp length_advice(_delta, _project, _est), do: "목표 길이에 맞습니다"

  defp changeset_error(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  defp inspect_error(%Ecto.Changeset{} = cs), do: changeset_error(cs)
  defp inspect_error(reason) when is_binary(reason), do: reason
  defp inspect_error(reason), do: inspect(reason)
end