defmodule VideoTool.PipelineTest do
  @moduledoc """
  파이프라인이 실제로 도는지 확인하는 최소 검사.

  덮는 것: 대본 길이 계산, next/1 의 단계 전이, 프롬프트 자리표시자 치환,
  허용 수치 주입이 INFO 단계에만 붙는지, 발행 플랫폼 제약.
  """
  use VideoTool.DataCase, async: true

  alias VideoTool.{Jobs, Media, Pipeline, Projects, Prompt, Publishing}

  setup do
    Code.eval_file("priv/repo/seeds.exs")

    {:ok, project} =
      Projects.create_project(%{
        "title" => "병자호란",
        "topic" => "1636 병자호란",
        "target_sec" => 60,
        "style_slug" => "iso-lowpoly",
        "domain_slug" => "history-military",
        "voice_slug" => "mark",
        "output_folder" => System.tmp_dir!()
      })

    {:ok, project} = Projects.get_project(project.id)
    on_exit(fn -> File.rm_rf(project.work_dir) end)
    {:ok, project: project}
  end

  describe "대본 길이 계산" do
    test "공백을 뺀 글자 수를 초당 글자수로 나눈다", %{project: project} do
      # 590자 / 5.9 = 100.0초
      est = Projects.estimate_length(project.voice, String.duplicate("가", 590))

      assert est.chars == 590
      assert est.estimated_sec == 100.0
    end

    test "공백과 줄바꿈은 세지 않는다 — 안 그러면 실제보다 길게 나온다", %{project: project} do
      assert Projects.estimate_length(project.voice, "가 나\n다\t라").chars == 4
    end
  end

  describe "next/1 단계 전이" do
    test "대본이 없으면 에이전트에게 대본을 요구한다", %{project: project} do
      result = Pipeline.next(project)

      assert result.stage == "script"
      assert result.action == "agent"
      # 목표 글자수를 알려줘야 60초 대본이 130초로 나오는 일이 안 생긴다
      assert result.context.target_chars == 354
    end

    test "대본만 있으면 장면 분할을 요구한다", %{project: project} do
      {:ok, _script, _est} = Projects.save_script(project, "본문", nil, "draft")
      assert %{stage: "scenes", action: "agent"} = Pipeline.next(project)
    end

    test "장면까지 있으면 허용 수치를 요구한다", %{project: project} do
      seed_scenes(project)
      assert %{stage: "facts", action: "agent"} = Pipeline.next(project)
    end

    test "허용 수치까지 채우면 CLEAN 프롬프트를 클립보드에 넣는다", %{project: project} do
      seed_scenes(project)
      seed_facts(project)

      result = Pipeline.next(project)

      assert result.stage == "clean"
      assert result.action == "clipboard"
      assert result.clipboard_written
      assert result.prompt_chars > 0
    end

    test "CLEAN 검증에 걸리면 문제 컷 재생성으로 전환된다", %{project: project} do
      seed_scenes(project)
      seed_facts(project)

      {:ok, _} =
        Media.create_asset(%{
          project_id: project.id,
          kind: "clean",
          file_path: "C:/tmp/S01.png"
        })

      {:ok, _} =
        Jobs.record_validation(project.id, "clean", false, %{"count" => false}, [
          %{"scene_no" => 1, "issue" => "허용 외 수치 '30일'"}
        ])

      result = Pipeline.next(project)

      assert result.action == "fix"
      assert [%{"scene_no" => 1}] = result.problems
      assert result.message =~ "1번 컷"
    end
  end

  describe "프롬프트 조립" do
    test "자리표시자가 남지 않는다", %{project: project} do
      seed_scenes(project)
      seed_facts(project)

      for stage <- ["clean", "info", "video"] do
        {:ok, text} = Prompt.render(project, stage)
        refute text =~ "{{", "#{stage} 단계에 치환 안 된 자리표시자가 남았다"
      end
    end

    test "허용 수치는 INFO 단계에만 주입된다", %{project: project} do
      seed_scenes(project)
      seed_facts(project)

      {:ok, clean} = Prompt.render(project, "clean")
      {:ok, info} = Prompt.render(project, "info")

      assert info =~ "70킬로미터"
      assert info =~ "이 목록에 없는 숫자"
      # CLEAN 에 수치가 새어 들어가면 인포그래픽 없는 이미지에 숫자가 그려진다
      refute clean =~ "70킬로미터"
    end

    test "scene_no 를 주면 그 장면만 나온다", %{project: project} do
      seed_scenes(project)
      seed_facts(project)

      {:ok, text} = Prompt.render(project, "clean", scene_no: 2)

      assert text =~ "IMAGE 02"
      refute text =~ "IMAGE 01"
    end
  end

  describe "장면 저장" do
    test "다시 저장해도 Scene 이 새로 생기지 않는다 — 붙어 있던 이미지 연결이 유지된다", %{project: project} do
      seed_scenes(project)
      [scene | _] = Projects.scenes(project.id)

      {:ok, _} =
        Media.create_asset(%{
          project_id: project.id,
          scene_id: scene.id,
          kind: "clean",
          file_path: "C:/tmp/S01.png"
        })

      {:ok, result} =
        Projects.save_scenes(project, [
          %{"scene_no" => 1, "target_sec" => 4.0, "shot_prompt" => "고친 문장"}
        ])

      assert result.updated == 1
      assert result.created == 0

      [asset] = Media.list_assets(project.id, "clean")
      assert asset.scene_id == scene.id
    end
  end

  describe "발행" do
    test "플랫폼 상한을 넘으면 잘라내고 무엇이 잘렸는지 알려준다", %{project: project} do
      {:ok, channel} = Publishing.fetch_channel("yt-main")
      render = a_render(project)

      {:ok, publication, warnings} =
        Publishing.save_publish_meta(project, channel, render, %{
          "title" => String.duplicate("가", 150),
          "description" => "설명"
        })

      assert String.length(publication.title) == 100
      assert Enum.any?(warnings, &(&1 =~ "제목"))
    end

    test "confirm 없이 부르면 발행하지 않는다", %{project: project} do
      {:ok, channel} = Publishing.fetch_channel("yt-main")

      assert {:error, msg} = Publishing.publish(project, channel, a_render(project), nil)
      assert msg =~ "confirm"
    end

    test "최종 검증을 통과 못 하면 사전 검사에서 막힌다", %{project: project} do
      {:ok, channel} = Publishing.fetch_channel("yt-main")

      assert {:error, reasons} = Publishing.publish(project, channel, a_render(project), true)
      assert Enum.any?(reasons, &(&1 =~ "최종 검증"))
      assert Enum.any?(reasons, &(&1 =~ "토큰"))
    end
  end

  # ── 도우미 ──────────────────────────────────────────────────────

  defp a_render(project) do
    {:ok, render} =
      Media.create_render(%{
        project_id: project.id,
        aspect: "16:9",
        file_path: "C:/tmp/out.mp4",
        duration_sec: 100.0,
        burn_subtitles: true
      })

    render
  end

  defp seed_scenes(project) do
    {:ok, _script, _est} = Projects.save_script(project, "본문입니다", nil, "draft")

    {:ok, _} =
      Projects.save_scenes(project, [
        %{
          "scene_no" => 1,
          "target_sec" => 3.5,
          "purpose" => "hook",
          "segment_text" => "독일군이 이 얘기를 들었으면",
          "shot_prompt" => "SHOT S01: Isometric low-poly diorama of tanks",
          "info_instruction" => "전차 종대에 회색 발광 외곽선. 상단 라벨 1940년 프랑스.",
          "camera_plan" => %{"early" => "넓은 등각", "mid" => "수평 트래킹", "late" => "줌아웃"},
          "expected_labels" => ["1940년 프랑스"]
        },
        %{
          "scene_no" => 2,
          "target_sec" => 4.0,
          "purpose" => "setup",
          "segment_text" => "하루 70킬로미터를 달렸다",
          "shot_prompt" => "SHOT S02: Isometric map with advancing column",
          "info_instruction" => "경로선 주황. 라벨 70킬로미터.",
          "expected_labels" => ["70킬로미터"]
        }
      ])
  end

  defp seed_facts(project) do
    script = Projects.active_script(project.id)

    {:ok, _} =
      Projects.save_allowed_facts(script, [
        %{"kind" => "number", "value" => "70킬로미터", "note" => "1940 구데리안 기갑부대 최고 기록"},
        %{"kind" => "date", "value" => "1940년 프랑스", "note" => ""}
      ])
  end
end