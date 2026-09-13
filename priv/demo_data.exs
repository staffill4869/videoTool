# mix run priv/demo_data.exs
#
# 컨택트시트 화면을 눈으로 확인하기 위한 데모 프로젝트.
# ffmpeg 로 그림을 만들어 Flow zip 을 흉내 낸다. INFO 파일명은 일부러 내용과 반대로 붙여서
# "파일명이 아니라 그림으로 매핑된다" 는 걸 화면에서 바로 보이게 한다.
#
# 지워도 된다: Repo.delete(project) 하면 딸린 자산까지 같이 지워진다.

alias VideoTool.{Ingest, Projects}

work = Path.join(System.tmp_dir!(), "vcrm_demo_#{System.os_time(:second)}")
File.mkdir_p!(work)

# Windows 에서 drawtext 는 fontconfig 를 못 찾는다. 폰트 파일을 직접 준다.
# 필터 문법상 드라이브 콜론을 이스케이프해야 한다.
font = "C\\:/Windows/Fonts/malgun.ttf"

unless File.exists?("C:/Windows/Fonts/malgun.ttf") do
  raise "맑은 고딕(malgun.ttf)을 찾을 수 없습니다. 다른 한글 폰트 경로로 바꾸세요."
end

ff = fn args ->
  {out, code} = System.cmd("ffmpeg", ["-v", "error", "-y" | args], stderr_to_stdout: true)
  if code != 0, do: raise("ffmpeg 실패: #{out}")
end

# 서로 확실히 구분되는 3장 — 흰 막대의 가로 위치가 장면마다 다르다.
# (testsrc2 의 다른 시각을 쓰면 9x8 로 줄였을 때 세 장이 같은 해시가 나온다.)
clean =
  for n <- 1..3 do
    path = Path.join(work, "clean_#{n}.png")
    x = 40 + (n - 1) * 220

    ff.([
      "-f", "lavfi", "-i", "color=c=#1b2838:s=640x360",
      "-vf", "drawbox=x=#{x}:y=60:w=140:h=240:color=#e8e4d9:t=fill",
      "-frames:v", "1", path
    ])

    path
  end

# CLEAN 위에 라벨 상자를 얹은 것 = INFO. 이름 순서는 내용과 반대로.
info_names = %{1 => "z_01_info.png", 2 => "m_02_info.png", 3 => "a_03_info.png"}

info =
  for n <- 1..3 do
    path = Path.join(work, info_names[n])

    # 라벨은 흰 막대와 겹치지 않게 아래쪽 띠에 둔다 — 밑그림이 유지돼야 제 짝을 찾는다.
    ff.([
      "-i", Enum.at(clean, n - 1),
      "-vf",
      "drawbox=x=20:y=310:w=210:h=38:color=#c0392b:t=fill," <>
        "drawtext=fontfile='#{font}':text='#{n}번 장면':x=34:y=318:fontsize=26:fontcolor=white",
      "-frames:v", "1", path
    ])

    path
  end

# 앞 4초 CLEAN, 뒤 4초 INFO = 8초 클립.
clips =
  for n <- 1..3 do
    path = Path.join(work, "clip_#{n}.mp4")

    ff.([
      "-loop", "1", "-t", "4", "-i", Enum.at(clean, n - 1),
      "-loop", "1", "-t", "4", "-i", Enum.at(info, n - 1),
      "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]",
      "-map", "[v]", "-r", "12", "-pix_fmt", "yuv420p", path
    ])

    path
  end

zip = fn name, files ->
  path = Path.join(work, name)
  entries = Enum.map(files, &{String.to_charlist(Path.basename(&1)), File.read!(&1)})
  {:ok, _} = :zip.create(String.to_charlist(path), entries)
  path
end

{:ok, project} =
  Projects.create_project(%{
    "title" => "데모 — 컨택트시트 확인",
    "topic" => "매핑이 파일명이 아니라 그림으로 되는지 눈으로 보기",
    "target_sec" => 24,
    "style_slug" => "iso-lowpoly",
    "domain_slug" => "history-military",
    "voice_slug" => "mark",
    "output_folder" => work
  })

{:ok, project} = Projects.get_project(project.id)
{:ok, _script, _} = Projects.save_script(project, "데모용 대본입니다. " <> String.duplicate("가", 120), nil, "draft")

{:ok, _} =
  Projects.save_scenes(
    project,
    for n <- 1..3 do
      %{
        "scene_no" => n,
        "target_sec" => 8.0,
        "purpose" => Enum.at(~w(hook setup close), n - 1),
        "segment_text" => "#{n}번 장면의 대본 구간입니다",
        "shot_prompt" => "SHOT S0#{n}: demo",
        "info_instruction" => "상단 좌측에 '#{n}번 장면' 라벨",
        "camera_plan" => %{"early" => "넓게", "mid" => "트래킹", "late" => "줌아웃"},
        "expected_labels" => ["#{n}번 장면"]
      }
    end
  )

# 화이트리스트. 화면에 뜬 "1번 장면" 을 허용 목록에 넣어야 검증이 통과한다.
# 여기서 한 줄을 지우고 다시 돌리면, 그 장면만 "허용 외 수치" 로 잡히는 걸 볼 수 있다.
script = Projects.active_script(project.id)

{:ok, _} =
  Projects.save_allowed_facts(script, [
    %{"kind" => "number", "value" => "1번 장면", "note" => "데모 라벨"},
    %{"kind" => "number", "value" => "2번 장면", "note" => "데모 라벨"},
    %{"kind" => "number", "value" => "3번 장면", "note" => "데모 라벨"}
  ])

for {name, files} <- [
      {"flow_clean.zip", clean},
      {"flow_info.zip", info},
      {"flow_clips.zip", clips}
    ] do
  {:ok, summary} = Ingest.run(project, zip.(name, files))
  IO.puts("#{name}: #{summary.extracted}개 중 #{summary.mapped}개 매핑 (#{summary.method})")
end

IO.puts("""

데모 준비 완료 — http://localhost:4300/projects/#{project.id}

INFO 파일명은 z_01 / m_02 / a_03 순서인데 내용은 1 / 2 / 3 번이다.
이름대로 붙었다면 순서가 뒤집혀 보일 것이고, 그림대로 붙었다면 맞게 보인다.

지우려면:  VideoTool.Repo.delete!(VideoTool.Repo.get!(VideoTool.Projects.Project, #{project.id}))
""")