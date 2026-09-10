defmodule VideoCRM.WorkTest do
  @moduledoc """
  작업 큐 · 시리즈 · 성과 집계.

  여기 있는 검사는 대부분 실제로 났던 버그를 고정한 것이다.
  """
  use VideoCRM.DataCase, async: false

  alias VideoCRM.{Insights, Media, Projects, Publishing, Series, Work}

  setup do
    Code.eval_file("priv/repo/seeds.exs")
    {:ok, style} = VideoCRM.Presets.fetch_style("iso-lowpoly")
    {:ok, domain} = VideoCRM.Presets.fetch_domain("history-military")
    {:ok, voice} = VideoCRM.Presets.fetch_voice("mark")
    {:ok, style: style, domain: domain, voice: voice}
  end

  defp make_project(title, attrs \\ %{}) do
    {:ok, p} =
      Projects.create_project(
        Map.merge(
          %{
            "title" => title,
            "target_sec" => 30,
            "style_slug" => "iso-lowpoly",
            "domain_slug" => "history-military",
            "voice_slug" => "mark",
            "output_folder" => System.tmp_dir!()
          },
          attrs
        )
      )

    {:ok, p} = Projects.get_project(p.id)
    on_exit(fn -> File.rm_rf(p.work_dir) end)
    p
  end

  defp finish(project) do
    {:ok, _, _} = Projects.save_script(project, "본문", nil, "draft")

    {:ok, _} =
      Projects.save_scenes(project, [
        %{"scene_no" => 1, "target_sec" => 4.0, "shot_prompt" => "S01", "expected_labels" => ["가"]}
      ])

    script = Projects.active_script(project.id)
    {:ok, _} = Projects.save_allowed_facts(script, [%{"kind" => "place", "value" => "남한산성"}])
    project
  end

  describe "작업 큐" do
    test "끝난 프로젝트가 앞에 있어도 뒤쪽 일을 찾아낸다" do
      # DB 에서 먼저 1건으로 자르고 거르면, 가장 오래된 프로젝트가 이미 끝났을 때
      # "할 일 없음" 이 된다 — 뒤에 일이 쌓여 있는데도. 실제로 그렇게 났던 버그다.
      finish(make_project("끝난 것"))
      later = make_project("할 일 있는 것")

      {:ok, job} = Work.next_job()

      assert job.project_id == later.id
      assert job.task == "write_script"
    end

    test "단계에 따라 다음 일이 바뀐다" do
      project = make_project("단계")

      assert %{task: "write_script"} = describe_now(project)

      {:ok, _, _} = Projects.save_script(project, "본문", nil, "draft")
      assert %{task: "split_scenes"} = describe_now(project)

      {:ok, _} =
        Projects.save_scenes(project, [%{"scene_no" => 1, "target_sec" => 4.0, "shot_prompt" => "S01"}])

      assert %{task: "write_allowed_facts"} = describe_now(project)
    end

    test "목표 글자수를 함께 준다 — 없으면 60초 대본이 130초로 나온다" do
      project = make_project("길이", %{"target_sec" => 60})
      assert describe_now(project).target_chars == 354
    end

    test "다 끝난 프로젝트만 있으면 할 일이 없다" do
      finish(make_project("완료"))
      assert {:ok, nil} = Work.next_job()
    end

    defp describe_now(project) do
      Work.pending_jobs(50) |> Enum.find(&(&1.project_id == project.id))
    end
  end

  describe "언어판" do
    test "CLEAN 을 다시 만들지 않고 원본 것을 그대로 쓴다" do
      source = make_project("원본")
      {:ok, _, _} = Projects.save_script(source, "본문", nil, "draft")

      {:ok, _} =
        Projects.save_scenes(source, [
          %{"scene_no" => 1, "target_sec" => 4.0, "shot_prompt" => "S01", "expected_labels" => ["가"]},
          %{"scene_no" => 2, "target_sec" => 4.0, "shot_prompt" => "S02", "expected_labels" => ["나"]}
        ])

      for scene <- Projects.scenes(source.id) do
        {:ok, _} =
          Media.create_asset(%{
            project_id: source.id,
            scene_id: scene.id,
            kind: "clean",
            file_path: "C:/tmp/S#{scene.scene_no}.png",
            phash: "abc123",
            status: "mapped"
          })
      end

      {:ok, result} = Projects.create_language_variant(source, "en")

      assert result.scenes == 2
      assert result.clean_reused == 2

      # 같은 파일을 가리켜야 한다. 복사하면 같은 그림이 두 벌 생긴다.
      [a | _] = Media.list_assets(result.project.id, "clean")
      assert a.file_path =~ "C:/tmp/S"

      # 라벨은 비워야 한다 — 그 언어로 다시 정한다
      assert Enum.all?(Projects.scenes(result.project.id), &(&1.expected_labels == []))
    end

    test "언어판에는 '새로 쓰기' 가 아니라 '번역' 이 배정된다" do
      source = finish(make_project("원본2"))
      {:ok, result} = Projects.create_language_variant(source, "ja")

      job = Work.pending_jobs(50) |> Enum.find(&(&1.project_id == result.project.id))

      assert job.task == "translate_script"
      assert job.source.script == "본문"
      assert job.instruction =~ "새로 쓰지 마세요"
    end

    test "표기언어 변수가 프로젝트 언어에서 자동으로 채워진다" do
      source = finish(make_project("원본3"))
      {:ok, result} = Projects.create_language_variant(source, "en")
      {:ok, variant} = Projects.get_project(result.project.id)

      assert VideoCRM.Prompt.variables(variant)["표기언어"] == "영어(English)"
      assert VideoCRM.Prompt.variables(source)["표기언어"] == "한국어"
    end
  end

  describe "프로젝트별 프롬프트" do
    test "전용 프롬프트가 있으면 공용 템플릿 대신 쓴다" do
      project = finish(make_project("전용"))

      refute VideoCRM.Prompt.overridden?(project, "clean")

      {:ok, project} = Projects.set_prompt_override(project, "clean", "이 프로젝트만의 프롬프트")
      {:ok, project} = Projects.get_project(project.id)

      assert VideoCRM.Prompt.overridden?(project, "clean")
      {:ok, text} = VideoCRM.Prompt.render(project, "clean")
      assert text =~ "이 프로젝트만의 프롬프트"

      {:ok, project} = Projects.set_prompt_override(project, "clean", nil)
      {:ok, project} = Projects.get_project(project.id)
      refute VideoCRM.Prompt.overridden?(project, "clean")
    end
  end

  describe "시리즈" do
    test "대기가 상한에 차면 더 만들지 않는다", ctx do
      {:ok, series} =
        Series.create(%{
          "name" => "테스트",
          "style_id" => ctx.style.id,
          "domain_id" => ctx.domain.id,
          "voice_id" => ctx.voice.id,
          "interval_minutes" => 1,
          "max_pending" => 2,
          "active" => true,
          "output_folder" => System.tmp_dir!()
        })

      {:ok, series} = Series.get(series.id)
      {:ok, _} = Series.spawn_project(series)
      {:ok, series} = Series.get(series.id)
      {:ok, _} = Series.spawn_project(series)

      assert Series.pending_count(series.id) == 2

      # 상한에 걸리면 건너뛴다. 안 그러면 에이전트가 대본을 안 쓰는 동안 빈 프로젝트가 쌓인다.
      {:ok, series} = Series.get(series.id)
      {:ok, series} = Series.update(series, %{"next_run_at" => DateTime.utc_now() |> DateTime.add(-60)})

      assert [{:skipped, _, 2}] = Series.run_due()
      assert Series.pending_count(series.id) == 2
    end

    test "꺼져 있으면 돌지 않는다", ctx do
      {:ok, series} =
        Series.create(%{
          "name" => "꺼짐",
          "style_id" => ctx.style.id,
          "domain_id" => ctx.domain.id,
          "voice_id" => ctx.voice.id,
          "interval_minutes" => 1,
          "active" => false
        })

      assert is_nil(series.next_run_at)
      assert Series.run_due() == []
    end
  end

  describe "성과 집계" do
    test "발행물마다 마지막 측정치만 합산한다" do
      project = finish(make_project("성과"))
      {:ok, channel} = Publishing.fetch_channel("yt-main")

      # 렌더가 없어도 등록된다 — 밖에서 손으로 올린 영상이 그렇다
      {:ok, pub} =
        Insights.register_published(project, channel, nil, %{"external_url" => "https://youtu.be/x"})

      {:ok, _} = Insights.record(pub.id, %{views: 100, likes: 10, comments: 1})
      Process.sleep(1100)
      {:ok, _} = Insights.record(pub.id, %{views: 250, likes: 22, comments: 3})

      d = Insights.dashboard()

      # 100 + 250 = 350 이 아니라 250 이어야 한다. 누적이 아니라 현재 값이다.
      assert d.totals.views == 250
      assert d.totals.likes == 22
      assert d.totals.count == 1
      assert length(Insights.history(pub.id)) == 2
    end

    test "언어별로 쪼갠다" do
      source = finish(make_project("한국어판"))
      {:ok, result} = Projects.create_language_variant(source, "en")
      {:ok, variant} = Projects.get_project(result.project.id)
      {:ok, channel} = Publishing.fetch_channel("yt-main")

      {:ok, a} = Insights.register_published(source, channel, nil, %{})
      {:ok, b} = Insights.register_published(variant, channel, nil, %{})
      {:ok, _} = Insights.record(a.id, %{views: 1000})
      {:ok, _} = Insights.record(b.id, %{views: 300})

      by_language = Map.new(Insights.dashboard().by_language, &{&1.key, &1.views})

      assert by_language["ko"] == 1000
      assert by_language["en"] == 300
    end
  end
end