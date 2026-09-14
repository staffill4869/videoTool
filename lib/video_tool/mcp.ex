defmodule VideoTool.MCP do
  @moduledoc """
  MCP 툴 정의와 디스패치.

  이 서버에는 LLM 이 없다. 창작(대본·장면·SHOT 문장·허용 수치)은 에이전트가 하고
  여기서는 저장·조립·클립보드 주입·검증 같은 기계적인 일만 한다.

  아직 구현되지 않은 단계는 성공한 척하지 않고 `ok: false` 로 명시적으로 실패한다.
  """

  alias VideoTool.Publishing.GoogleOAuth
  alias VideoTool.{Flow, Ingest, Jobs, Media, Pipeline, Projects, Prompt, Publishing, Presets, Series, Work, Insights, Settings}

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
      tool(
        "list_projects",
        "프로젝트 목록과 단계별 진행 상황. 무인 루프가 **어느 프로젝트를 이어서 할지 고르는 곳**이다. " <>
          "단계(clean·info·clip)가 몇 개씩 찼는지, 완성본과 발행이 됐는지 한 번에 보여준다",
        %{"unfinished_only" => bool("완성본이 없는 것만. 기본 true")}
      ),
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
      tool(
        "save_narration",
        "에이전트가 만든 음성 파일을 등록하고 무음 정렬 · 장면 시간 · 자막을 만든다. " <>
          "힉스필드 MCP 로 음성을 만든 뒤 그 결과 URL 이나 로컬 경로를 넘기세요.",
        %{
          "project_id" => int("프로젝트 id"),
          "file" => str("음성 파일 경로 또는 http(s) URL"),
          "scene_secs" =>
            %{
              "type" => "object",
              "description" =>
                "장면 번호 → 그 장면 음성 길이(초). 주면 장면 뒤 무음을 없애려고 " <>
                  "클립을 그 길이로 잘라 쓴다 (마지막 장면은 통째로 남긴다). " <>
                  "장면별 음성을 무음 없이 이어 붙였을 때만 주세요."
            }
        },
        ["project_id", "file"]
      ),
      tool(
        "check_video",
        "발행하기 전에 완성본을 검사한다. 정렬·클립·자막·썸네일·길이. " <>
          "**publish 하기 직전에 반드시 부르고, 걸린 항목은 고친 뒤 올린다**",
        %{"project_id" => int("프로젝트 id")},
        ["project_id"]
      ),
      tool(
        "drop_assets",
        "잘못 들어온 자산을 그 단계째 지운다. 다른 편의 결과를 긁어왔을 때 쓴다. " <>
          "confirm 이 true 가 아니면 몇 건인지만 알려주고 지우지 않는다",
        %{
          "project_id" => int("프로젝트 id"),
          "kind" => str("clean | info | clip"),
          "confirm" => %{"type" => "boolean", "description" => "실제로 지울 때만 true"}
        },
        ["project_id", "kind"]
      ),
      tool(
        "thumbnail_brief",
        "이 편의 섬네일을 어떻게 그릴지 지시문을 내준다. 그림 생성 전에 부르세요. " <>
          "영양제 시리즈는 먹기 전/후 좌우 비교, 나머지는 한 장면. " <>
          "제목은 2~5글자로 구석에 넣고 프로젝트 이름은 넣지 않습니다",
        %{"project_id" => int("프로젝트 id")},
        ["project_id"]
      ),
      tool(
        "save_thumbnail",
        "만든 섬네일을 완성본에 붙인다. 발행할 때 이 파일이 유튜브 섬네일로 올라간다",
        %{
          "project_id" => int("프로젝트 id"),
          "file" => str("이미지 경로 또는 http(s) URL")
        },
        ["project_id", "file"]
      ),
      tool(
        "assemble",
        "클립을 장면 순서로 리타이밍해 이어 붙이고 나레이션과 자막을 얹어 완성본을 만든다",
        %{
          "project_id" => int("프로젝트 id"),
          "burn_subtitles" => bool("자막 하드번 여부. 기본 true")
        },
        ["project_id"]
      ),
      tool(
        "validate",
        "단계 결과를 검증하고 기록한다. publish 는 stage: \"final\" 이 통과돼 있어야 진행된다",
        %{
          "project_id" => int("프로젝트 id"),
          "stage" => str("clean | info | clips | final")
        },
        ["project_id", "stage"]
      ),
      tool("make_vertical", "가로 완성본에서 9:16 세로본 생성 (4주차)", %{
        "project_id" => int("프로젝트 id")
      }, ["project_id"]),
      tool(
        "flow_new_project",
        "Flow 에 새 프로젝트를 열고 그 프로젝트의 화면비·장면수 규칙을 상시 지시로 박는다. " <>
          "편마다 따로 열어야 이전 편 이미지가 섞이지 않는다. " <>
          "Flow 탭이 없거나 홈·소개 화면일 때 이걸 부르면 된다 — 사람에게 열어달라고 하지 말 것",
        %{"project_id" => int("프로젝트 id. 화면비 규칙을 이 프로젝트 기준으로 넣는다")},
        ["project_id"]
      ),
      tool(
        "flow_harvest",
        "Flow 화면에 있는 결과물을 받아 자산으로 등록하고 장면에 자동 배정한다. " <>
          "단계가 끝나면 자동으로 돌지만, 중간에 끊겼거나 다시 받고 싶을 때 직접 부른다",
        %{
          "project_id" => int("프로젝트 id"),
          "stage" => str("clean | info | video")
        },
        ["project_id", "stage"]
      ),
      tool(
        "contact_sheet",
        "한 단계 결과를 장면 순서대로 한 장에 붙여 준다. 그 파일을 **눈으로 보고** " <>
          "장면 배정이 맞는지 확인한 뒤 틀렸으면 remap_scenes 로 고친다. " <>
          "배정 신뢰도가 높아도 장면 순서는 뒤섞여 있을 수 있으므로 이 확인을 건너뛰지 말 것",
        %{
          "project_id" => int("프로젝트 id"),
          "kind" => str("clean | info | clip")
        },
        ["project_id", "kind"]
      ),
      tool(
        "remap_scenes",
        "장면 배정을 손으로 고친다. CLEAN 이 나오면 이미지를 눈으로 보고 순서를 확인할 것 — " <>
          "배정 신뢰도가 높아도 장면 순서는 통째로 섞여 있을 수 있다. " <>
          "order 는 '이 장면에 지금 몇 번 그림을 쓸지' 의 나열이다: [8,2,7,1,6,5,3,4]",
        %{
          "project_id" => int("프로젝트 id"),
          "kind" => str("clean | info | clip"),
          "order" => %{
            "type" => "array",
            "items" => %{"type" => "integer"},
            "description" => "장면 1번부터 차례로, 그 자리에 쓸 지금 장면 번호"
          }
        },
        ["project_id", "kind", "order"]
      ),
      tool("settings_status", "이 PC 에서 무엇이 준비됐는지 (API 키·OAuth·ffmpeg·tesseract·Flow 브라우저)", %{}),
      tool(
        "set_credential",
        "자격증명을 저장한다. DPAPI 로 암호화해 파일에 두고 DB 에는 넣지 않는다. " <>
          "값을 비우면 지워지고 .env 값으로 돌아간다",
        %{
          "name" => str("google_api_key | google_client_id | google_client_secret"),
          "value" => str("값. 비우면 삭제")
        },
        ["name"]
      ),
      tool(
        "login_channel",
        "채널에 구글 로그인을 시작한다. **OAuth 는 사람이 브라우저에서 동의해야 끝난다** — " <>
          "이 툴은 인증 URL 을 만들고 브라우저를 열어준다. 그 다음 channel_status 로 확인하면 된다",
        %{
          "channel_slug" => str("채널 slug (예: yt-main)"),
          "open_browser" => %{"type" => "boolean", "description" => "브라우저를 직접 열지 (기본 true)"}
        },
        ["channel_slug"]
      ),
      tool(
        "channel_status",
        "채널 연결 상태. login_channel 뒤에 이걸로 확인한다",
        %{"channel_slug" => str("생략하면 전부")}
      ),
      tool("logout_channel", "채널 연결을 끊는다. 토큰만 지우고 발행 이력은 남긴다", %{
        "channel_slug" => str("채널 slug")
      }, ["channel_slug"]),
      tool(
        "flow_open_browser",
        "Flow 용 Chrome 을 디버그 포트로 띄운다. 이미 떠 있으면 그대로 둔다. " <>
          "처음이면 그 창에서 사람이 구글 로그인을 해야 한다 — 자동화는 로그인하지 않는다",
        %{}
      ),
      tool(
        "flow_generate",
        "Flow 에 이 단계 프롬프트를 넣고 생성을 눌러 결과가 나올 때까지 기다린 뒤 다운로드까지 한다. " <>
          "Flow 에는 API 가 없어 브라우저를 직접 조종한다. 분 단위로 걸리므로 백그라운드로 돌고 " <>
          "바로 돌아온다 — 진행은 next 나 flow_job 으로 확인한다",
        %{
          "project_id" => int("프로젝트 id"),
          "stage" => str("clean | info | video. 생략하면 지금 필요한 단계"),
          "scene_nos" => %{
            "type" => "array",
            "items" => %{"type" => "integer"},
            "description" => "만들 장면 번호. 생략하면 아직 결과가 없는 장면만 넣는다"
          }
        },
        ["project_id"]
      ),
      tool("flow_job", "지금 돌고 있는(또는 마지막) Flow 작업 상태", %{
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
      tool(
        "resume",
        "끝나지 않은 편들과 각각의 다음 할 일을 한 번에 준다. " <>
          "**중간에 멈춘 작업을 이어서 할 때 이것부터 부른다** — 어떤 편이 어디서 섰는지 여기 다 나온다",
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
  defp bool(desc), do: %{"type" => "boolean", "description" => desc}

  # ── 디스패치 ────────────────────────────────────────────────────

  def call(name, args) do
    # 누가 몰고 있는지와 무관하게 **활동 흔적을 남긴다.**
    # 예전에는 잠금 파일(run-agent.ps1 전용)로만 "작업 중" 을 판단해서,
    # Cowork 나 다른 클라이언트가 일하고 있어도 화면에는 "쉬는 중" 으로 보였다.
    # 서버에 들어오는 호출은 누가 불렀든 다 여기를 지난다.
    VideoTool.Activity.record(name)
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
        # 화면비를 되돌려준다. 생략하면 그림체 기본값(전부 16:9)을 물려받는데,
        # 그걸 모른 채 진행해서 세로로 만들려던 편이 통째로 가로로 나온 적이 있다.
        %{
          ok: true,
          project_id: project.id,
          work_dir: project.work_dir,
          status: project.status,
          aspect: project.aspect
        }

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

  # 중간에 멈춘 편을 이어서 하려면 "무엇이 어디서 섰는지" 를 한 번에 알아야 한다.
  # 이게 없으면 앱이 프로젝트 id 를 몰라 next 도 못 부른다 — 실제로 그래서 재개가 막혔다.
  defp handle("resume", _args) do
    items =
      Projects.list_projects()
      |> Enum.reject(&(&1.status == "done"))
      |> Enum.map(fn p ->
        scenes = length(Projects.scenes(p.id))
        mapped = Media.mapped_counts(p.id)

        %{
          project_id: p.id,
          title: p.title,
          status: p.status,
          aspect: p.aspect,
          pipeline: p.pipeline,
          scenes: scenes,
          clean: Map.get(mapped, "clean", 0),
          info: Map.get(mapped, "info", 0),
          clip: Map.get(mapped, "clip", 0),
          narration: not is_nil(Media.latest_narration(p.id)),
          rendered: not is_nil(Media.latest_render(p.id, p.aspect)),
          next_stage: next_stage(p, scenes, mapped)
        }
      end)

    {stuck, idle} = Enum.split_with(items, &(&1.next_stage != "발행 대기"))

    %{
      ok: true,
      unfinished: length(items),
      projects: stuck ++ idle,
      how: "이어서 하려면 next(project_id) 를 부르거나, next_stage 가 가리키는 도구를 직접 부르세요."
    }
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
        valid = Publishing.token_usable?(c)

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
      case Publishing.publish(project, channel, render, args["confirm"]) do
        {:ok, result} -> Map.merge(%{ok: true}, result)
        {:error, reasons} when is_list(reasons) -> %{ok: false, error: Enum.join(reasons, " / ")}
        {:error, reason} -> %{ok: false, error: to_string(reason)}
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

  # 순서가 곧 지시다. 무인 루프는 맨 위를 집어 간다.
  #
  # 진행도만 보고 고르면 **손이 많이 간 시리즈만 계속 밀어 주게 된다** — 다른 시리즈는
  # 켜 두기만 하고 영영 안 나간다. 그래서 먼저 **오래 못 나간 시리즈**를 앞에 놓고,
  # 그 안에서 가장 많이 진행된 편을 앞에 놓는다 (거의 다 된 것을 닫는 게 싸다).
  defp handle("list_projects", args) do
    only_unfinished = args["unfinished_only"] != false
    last_pub = Series.last_published_by_series()
    names = Map.new(Series.list(), &{&1.id, &1.name})
    now = DateTime.utc_now()

    rows =
      Projects.list_projects()
      |> Enum.map(fn p ->
        counts = Media.asset_counts(p.id)
        renders = length(Media.renders(p.id))
        scenes = length(Projects.scenes(p.id))
        done = (counts["clean"] || 0) + (counts["info"] || 0) + (counts["clip"] || 0)
        # 한 번도 안 나간 시리즈가 제일 급하다.
        starved = starved_hours(last_pub[p.series_id], now)

        %{
          id: p.id,
          title: p.title,
          status: p.status,
          series_id: p.series_id,
          series: names[p.series_id],
          series_quiet_hours: starved,
          scenes: scenes,
          clean: counts["clean"] || 0,
          info: counts["info"] || 0,
          clip: counts["clip"] || 0,
          renders: renders,
          progress: if(scenes > 0, do: Float.round(done / (scenes * 3), 2), else: 0.0),
          published: Publishing.publications(p.id) |> Enum.any?(&(&1.status == "published"))
        }
      end)
      |> then(fn list ->
        if only_unfinished, do: Enum.filter(list, &(&1.renders == 0 or not &1.published)), else: list
      end)
      |> Enum.sort_by(&{-&1.series_quiet_hours, -&1.progress, &1.id})

    %{
      ok: true,
      projects: rows,
      count: length(rows),
      order: "오래 못 나간 시리즈 먼저, 그 안에서 많이 진행된 편 먼저 — 맨 위부터 집으세요"
    }
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

  defp handle("settings_status", _args) do
    status = Settings.status()

    %{
      ok: true,
      ready: status |> Map.values() |> Enum.count(& &1.ready),
      total: map_size(status),
      items: status,
      redirect_uri: GoogleOAuth.redirect_uri()
    }
  end

  defp handle("set_credential", args) do
    name =
      case args["name"] do
        n when n in ~w(google_api_key google_client_id google_client_secret) -> String.to_existing_atom(n)
        _ -> nil
      end

    cond do
      is_nil(name) ->
        %{ok: false, error: "모르는 설정입니다: #{args["name"]}"}

      true ->
        case Settings.set(name, args["value"]) do
          {:ok, :cleared} -> %{ok: true, name: args["name"], cleared: true, source: Settings.source(name)}
          {:ok, _} -> %{ok: true, name: args["name"], masked: Settings.masked(name), source: "화면"}
          {:error, reason} -> %{ok: false, error: reason}
        end
    end
  end

  defp handle("login_channel", args) do
    with {:ok, channel} <- Publishing.fetch_channel(args["channel_slug"]),
         {:ok, url} <- GoogleOAuth.authorize_url(channel.slug) do
      opened = if args["open_browser"] == false, do: false, else: open_browser(url)

      %{
        ok: true,
        channel: channel.slug,
        authorize_url: url,
        browser_opened: opened,
        next:
          "브라우저에서 구글 계정을 고르고 동의하세요. 사람이 동의해야만 끝납니다. " <>
            "끝나면 channel_status 로 확인하세요.",
        note: "동의 화면이 '테스트' 상태면 refresh token 이 7일 뒤 만료됩니다."
      }
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("channel_status", args) do
    channels =
      case args["channel_slug"] do
        nil ->
          Publishing.list_channels()

        slug ->
          case Publishing.fetch_channel(slug) do
            {:ok, c} -> [c]
            _ -> []
          end
      end

    rows =
      Enum.map(channels, fn c ->
        %{
          slug: c.slug,
          platform: c.platform,
          display_name: c.display_name,
          connected: Publishing.token_usable?(c),
          token_saved: VideoTool.Credentials.exists?(c.credential_ref),
          token_expires_at: c.token_expires_at,
          aspect_required: c.aspect_required
        }
      end)

    %{ok: true, channels: rows, oauth_configured: GoogleOAuth.configured?()}
  end

  defp handle("logout_channel", args) do
    with {:ok, channel} <- Publishing.fetch_channel(args["channel_slug"]),
         {:ok, _} <- GoogleOAuth.disconnect(channel) do
      %{ok: true, channel: channel.slug, note: "토큰만 지웠습니다. 발행 이력은 남아 있습니다."}
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end


  defp handle("flow_open_browser", _args) do
    case Flow.open_browser() do
      {:ok, message} -> %{ok: true, message: message, next: "flow_status 로 로그인 여부를 확인하세요."}
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  defp handle("flow_generate", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]),
         {:ok, stage} <- resolve_stage(project, args["stage"]),
         nil <- Jobs.running_flow_job(project.id),
         want = wanted_scenes(project, stage, args["scene_nos"]),
         {:ok, text} <- Prompt.render(project, stage, scene_no: want),
         # 편집기가 열려 있는지까지 볼 필요는 없다 — run_stage 가 이 편의 Flow
         # 프로젝트를 스스로 연다. 여기서 prompt_box 를 요구하면 크롬을 새로 띄운
         # 직후처럼 홈 화면일 때 시작조차 못 한다. 붙을 수 있고 로그인돼 있으면 된다.
         {:ok, %{connected: true, page: page}} when page != "login" <- Flow.status(),
         {:ok, job} <- Flow.run_stage_async(project, stage, text, length(want)) do
      %{
        ok: true,
        job_id: job.id,
        stage: stage,
        scenes: want,
        prompt_chars: String.length(text),
        expect: length(want),
        message: "Flow 에 넣고 생성을 눌렀습니다. 결과가 나오면 자동으로 받아옵니다.",
        poll_after_sec: 30
      }
    else
      %{status: "running"} = job ->
        %{ok: false, error: "이미 '#{job.model}' 생성이 돌고 있습니다. 두 번 걸면 크레딧이 두 배로 나갑니다."}

      {:ok, status} ->
        %{
          ok: false,
          error: status[:hint] || "Flow 탭이 준비되지 않았습니다",
          next: "flow_open_browser 로 띄우고 그 창에서 구글 로그인을 하세요."
        }

      {:error, reason} ->
        %{ok: false, error: inspect_error(reason)}
    end
  end

  # 가장 최근 작업 하나만 본다. 예전에는 "돌고 있는 것 없으면 과거 실패 아무거나" 를 돌려줘서,
  # 새 작업이 성공해도 며칠 전 실패가 나왔다 — 그걸 보고 잘못 판단하게 된다.
  defp handle("flow_job", %{"project_id" => nil}), do: flow_jobs_overview()
  defp handle("flow_job", args) when not is_map_key(args, "project_id"), do: flow_jobs_overview()

  defp handle("flow_job", args) do
    case Jobs.latest_flow_job(args["project_id"]) do
      nil ->
        %{ok: true, state: "idle"}

      %{status: "running"} = job ->
        %{ok: true, state: "running", stage: job.model, started_at: job.requested_at, job_id: job.id}

      %{status: "failed"} = job ->
        %{ok: true, state: "failed", stage: job.model, error: job.error, at: job.finished_at, job_id: job.id}

      job ->
        %{ok: true, state: job.status, stage: job.model, note: job.error, at: job.finished_at, job_id: job.id}
    end
  end

  defp handle("flow_status", _args) do
    case Flow.status() do
      {:ok, status} ->
        ready = status[:flow_tab] == true and status[:prompt_box] == true
        running = Jobs.running_flow_jobs()

        Map.merge(
          %{
            ok: true,
            ready: ready,
            # 서버를 재시작하면 이것들이 실패로 찍힌다. restart.ps1 이 여기를 본다.
            running_jobs: length(running),
            running: Enum.map(running, &%{job_id: &1.id, project_id: &1.project_id, stage: &1.model})
          },
          status
        )
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

  # 에이전트(힉스필드 MCP)가 만든 음성 파일을 받아 정렬·자막까지 한다.
  # 서버는 TTS 를 직접 부르지 않는다 — 생성 API 키를 서버에 두지 않는다는 원칙 그대로다.
  defp handle("save_narration", args) do
    src = args["file"] || args["url"]

    cond do
      is_nil(src) or src == "" ->
        %{ok: false, error: "file 에 음성 파일 경로나 URL 을 주세요."}

      true ->
        with {:ok, project} <- Projects.get_project(args["project_id"]) do
          case VideoTool.Assembly.save_narration(project, src,
                 scene_secs: normalize_secs(args["scene_secs"])
               ) do
            {:ok, result} -> Map.put(result, :ok, true)
            {:error, reason} -> %{ok: false, error: inspect_error(reason)}
          end
        else
          {:error, reason} -> %{ok: false, error: inspect_error(reason)}
        end
    end
  end

  defp handle("check_video", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]) do
      VideoTool.Check.run(project) |> Map.put(:ok, true) |> Map.put(:project_id, project.id)
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("drop_assets", args) do
    kind = args["kind"]

    with {:ok, project} <- Projects.get_project(args["project_id"]),
         true <- kind in ~w(clean info clip) or {:error, "kind 는 clean · info · clip 중 하나입니다"} do
      assets = Media.list_assets(project.id, kind)

      if args["confirm"] == true do
        {:ok, n} = Media.drop_assets(project.id, kind)
        %{ok: true, deleted: n, kind: kind, note: "파일은 incoming 에 남습니다"}
      else
        %{
          ok: true,
          deleted: 0,
          would_delete: length(assets),
          kind: kind,
          note: "confirm: true 를 넣어야 지웁니다"
        }
      end
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("thumbnail_brief", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]) do
      %{ok: true, project_id: project.id, brief: VideoTool.Thumbnail.brief(project)}
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("save_thumbnail", args) do
    src = args["file"] || args["url"]

    if is_nil(src) or src == "" do
      %{ok: false, error: "file 에 이미지 경로나 URL 을 주세요."}
    else
      with {:ok, project} <- Projects.get_project(args["project_id"]),
           {:ok, result} <- VideoTool.Thumbnail.save(project, src) do
        Map.put(result, :ok, true)
      else
        {:error, reason} -> %{ok: false, error: inspect_error(reason)}
      end
    end
  end

  # 여는 것과 규칙을 박는 것을 나누지 않는다. 나누면 규칙 없는 프로젝트에서 생성이 돌아
  # 화면비가 틀어진다 — 실제로 12장이 전부 가로로 나왔다.
  defp handle("flow_new_project", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]) do
      case VideoTool.Flow.open_for(project) do
        {:ok, result} ->
          result |> Map.put(:ok, true) |> Map.put(:guideline, "#{project.aspect} 규칙을 넣었습니다")

        {:error, reason} ->
          %{ok: false, error: inspect_error(reason)}
      end
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("contact_sheet", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]),
         {:ok, r} <- VideoTool.Sheet.build(project, args["kind"] || "clean") do
      Map.put(r, :ok, true)
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("remap_scenes", args) do
    order = List.wrap(args["order"]) |> Enum.map(&trunc/1)

    case Media.remap_scenes(args["project_id"], args["kind"] || "clean", order) do
      {:ok, r} -> Map.put(r, :ok, true)
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("flow_harvest", args) do
    stage = args["stage"]

    if stage in ~w(clean info video) do
      with {:ok, project} <- Projects.get_project(args["project_id"]) do
        case VideoTool.Flow.harvest(project, stage, []) do
          {:ok, result} -> Map.put(result, :ok, true)
          {:error, reason} -> %{ok: false, error: inspect_error(reason)}
        end
      else
        {:error, reason} -> %{ok: false, error: inspect_error(reason)}
      end
    else
      %{ok: false, error: "stage 는 clean | info | video 중 하나여야 합니다"}
    end
  end

  defp handle("assemble", args) do
    with {:ok, project} <- Projects.get_project(args["project_id"]) do
      case VideoTool.Assembly.assemble(project, burn: Map.get(args, "burn_subtitles", true)) do
        {:ok, result} -> Map.put(result, :ok, true)
        {:error, reason} -> %{ok: false, error: inspect_error(reason)}
      end
    else
      {:error, reason} -> %{ok: false, error: inspect_error(reason)}
    end
  end

  defp handle("validate", args) do
    stage = args["stage"] || "final"

    if stage in ~w(clean info clips final) do
      with {:ok, project} <- Projects.get_project(args["project_id"]),
           {:ok, result} <- VideoTool.Validation.run(project, stage) do
        result |> Map.put(:ok, true) |> Map.put(:stage, stage)
      else
        {:error, reason} -> %{ok: false, error: inspect_error(reason)}
      end
    else
      %{ok: false, error: "stage 는 clean | info | clips | final 중 하나여야 합니다"}
    end
  end

  defp handle(name, _args) when name in ~w(generate_narration make_vertical) do
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

  # 단계를 안 주면 지금 필요한 단계를 고른다. 사람이 매번 어디까지 왔는지 세지 않아도 되게.
  defp resolve_stage(_project, stage) when stage in ["clean", "info", "video"], do: {:ok, stage}

  defp resolve_stage(project, _) do
    count = scene_count(project)
    mapped = Media.mapped_counts(project.id)

    cond do
      count == 0 -> {:error, "장면이 없습니다. save_scenes 를 먼저 부르세요."}
      mapped["clean"] < count -> {:ok, "clean"}
      mapped["info"] < count -> {:ok, "info"}
      mapped["clip"] < count -> {:ok, "video"}
      true -> {:error, "이 프로젝트는 생성이 다 끝났습니다."}
    end
  end

  defp scene_count(project), do: length(Projects.scenes(project.id))

  # 기본 브라우저로 연다. 실패해도 URL 은 돌려주므로 사람이 직접 열면 된다.
  defp open_browser(url) do
    case System.cmd("cmd", ["/c", "start", "", url], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

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

  # flow_job 을 project_id 없이 부르면 Ecto 가 nil 비교로 터졌다. 물어본 게
  # "지금 도는 게 있나" 이므로 터뜨리지 말고 그 답을 준다.
  defp flow_jobs_overview do
    running = Jobs.running_flow_jobs()

    %{
      ok: true,
      state: if(running == [], do: "idle", else: "running"),
      running_jobs: length(running),
      running: Enum.map(running, &%{job_id: &1.id, project_id: &1.project_id, stage: &1.model})
    }
  end

  # 한 번도 발행 안 한 시리즈는 아주 큰 값으로 둔다. "며칠째 못 나갔나" 보다 앞선다.
  defp starved_hours(nil, _now), do: 9_999
  defp starved_hours(at, now), do: div(DateTime.diff(now, DateTime.from_naive!(at, "Etc/UTC")), 3600)

  defp changeset_error(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  defp normalize_secs(m) when is_map(m) and map_size(m) > 0 do
    Map.new(m, fn {k, v} ->
      {to_string(k), if(is_binary(v), do: String.to_float(v), else: v * 1.0)}
    end)
  end

  defp normalize_secs(_), do: nil

  # 다시 부를 때 **아직 없는 장면만** 넣는다.
  # 8개를 통째로 다시 보내면 Flow 가 이미 있는 장면만 또 만들어 낸다 —
  # 실측: 6개가 찬 상태로 두 번을 더 돌렸는데 새 장면은 하나도 안 들어왔다.
  defp wanted_scenes(_project, _stage, nos) when is_list(nos) and nos != [],
    do: Enum.map(nos, &trunc/1)

  defp wanted_scenes(project, stage, _) do
    kind = if stage == "video", do: "clip", else: stage

    have =
      Media.list_assets(project.id, kind)
      |> Enum.filter(& &1.scene_id)
      |> MapSet.new(& &1.scene_id)

    all = Projects.scenes(project.id)
    missing = all |> Enum.reject(&MapSet.member?(have, &1.id)) |> Enum.map(& &1.scene_no)

    # 다 차 있으면 "전부 다시" 로 읽는다.
    if missing == [], do: Enum.map(all, & &1.scene_no), else: missing
  end

  defp inspect_error(%Ecto.Changeset{} = cs), do: changeset_error(cs)
  defp inspect_error(reason) when is_binary(reason), do: reason
  defp inspect_error(reason), do: inspect(reason)
  # resume 이 각 편의 다음 할 일을 한 줄로 말해 주는 곳.
  defp next_stage(project, scenes, mapped) do
    script = Projects.active_script(project.id)

    cond do
      is_nil(script) -> "대본 (save_script)"
      scenes == 0 -> "장면 분할 (save_scenes)"
      Projects.allowed_facts(script.id) == [] -> "허용 수치 (save_allowed_facts)"
      Map.get(mapped, "clean", 0) < scenes -> "CLEAN (flow_generate stage: clean)"
      Map.get(mapped, "info", 0) < scenes -> "INFO (flow_generate stage: info)"
      Map.get(mapped, "clip", 0) < scenes -> "VIDEO (flow_generate stage: video)"
      is_nil(Media.latest_narration(project.id)) -> "나레이션 (힉스필드 TTS → save_narration)"
      is_nil(Media.latest_render(project.id, project.aspect)) -> "합성 (assemble)"
      true -> "발행 대기"
    end
  end

end