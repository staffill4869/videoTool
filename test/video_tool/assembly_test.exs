defmodule VideoTool.AssemblyTest do
  use ExUnit.Case, async: true

  alias VideoTool.Assembly

  # 겹쳐 잇는 만큼 앞 조각을 길게 뽑아 두었으므로, 이어 붙인 총 길이는
  # "목표 길이의 합" 그대로여야 한다. 여기가 틀리면 나레이션이 밀린다.
  test "디졸브로 이어도 전체 길이는 목표 합과 같다" do
    targets = [7.92, 7.27, 6.94]
    overlaps = [0.3, 0.08, 0.0]
    durs = Enum.zip_with(targets, overlaps, &(&1 + &2))

    plan = Assembly.seam_plan(durs, overlaps)
    total = Enum.reduce(plan, Enum.at(durs, 0), fn {i, ov, _o}, acc -> acc + Enum.at(durs, i) - ov end)

    assert_in_delta total, Enum.sum(targets), 0.001
    assert [{1, 0.3, offset1}, {2, 0.08, _}] = plan
    assert_in_delta offset1, 7.92, 0.001
  end

  # 소리가 영상 중간에 커지던 원인은 dynaudnorm 이었다 (58편: 0초 -27.0 → 16초 -15.8 LUFS).
  # 레벨이 고정인지, 자동 정규화가 다시 안 끼었는지 여기서 막는다.
  test "합성 오디오 레벨은 고정이고 자동 정규화가 없다" do
    for {sfx?, bgm?} <- [{true, true}, {true, false}, {false, true}] do
      f = Assembly.audio_filter(sfx?, bgm?)

      refute f =~ "dynaudnorm"
      refute f =~ "loudnorm"
      assert f =~ "normalize=0"
      assert f =~ "alimiter"
      assert f =~ "[1:a]volume=1.4,apad[nar]"
    end

    # 섞는 갈래 수가 실제 입력 수와 맞아야 한다 — 어긋나면 ffmpeg 가 통째로 실패한다.
    assert Assembly.audio_filter(true, true) =~ "amix=inputs=3"
    assert Assembly.audio_filter(true, false) =~ "amix=inputs=2"
    assert Assembly.audio_filter(false, false) =~ "amix=inputs=1"
  end

  # 같은 편을 두 번 합성하지 않는다. pipeline.ex 가 "다음 할 일" 을 물을 때마다
  # 합성을 시작해서, 118 편 하나에 ffmpeg 8개가 붙고 서버 load 가 95 까지 갔다.
  test "합성은 한 프로젝트에 하나만 — 두 번째 호출은 기다리지 않고 거절한다" do
    me = self()

    first =
      Task.async(fn ->
        Assembly.with_lock(777, fn ->
          send(me, :locked)
          receive do: (:release -> :ok)
          :first_done
        end)
      end)

    assert_receive :locked, 1_000

    assert {:error, msg} = Assembly.with_lock(777, fn -> :should_not_run end)
    assert msg =~ "이미 합성 중"

    # 다른 편은 막히지 않는다.
    assert :other = Assembly.with_lock(778, fn -> :other end)

    send(first.pid, :release)
    assert :first_done = Task.await(first)

    # 끝나면 다시 잡힌다.
    assert :again = Assembly.with_lock(777, fn -> :again end)
  end

  # 117번 실측(2026-09-30): 대본을 존댓말로 고쳐 다시 읽혔는데 work/tts/s*.mp3 는
  # 평서문 판(합 59.14초)이 남아 있었다. 실제 음성은 53.79초라 자막이 6.4초 밀렸다.
  test "시간표 합이 음성 길이와 어긋나면 비율만 살리고 길이를 맞춘다" do
    stale =
      [7.576, 7.445, 7.288, 7.863, 6.844, 7.993, 7.393, 7.739]
      |> Enum.with_index()
      |> Enum.scan({nil, 0.0}, fn {d, i}, {_, cursor} ->
        {%{"scene_id" => i + 1, "start" => cursor, "end" => cursor + d, "target_sec" => d},
         cursor + d}
      end)
      |> Enum.map(&elem(&1, 0))

    assert_in_delta Enum.sum(Enum.map(stale, & &1["target_sec"])), 60.141, 0.01

    fixed = Assembly.fit_to_audio(stale, 53.786)
    total = Enum.sum(Enum.map(fixed, & &1["target_sec"]))

    # 음성 53.786 + 마지막 여운 1.0
    assert_in_delta total, 54.786, 0.05
    # 장면 사이가 벌어지거나 겹치지 않는다.
    assert hd(fixed)["start"] == 0.0
    assert_in_delta List.last(fixed)["end"], total, 0.05

    Enum.zip(fixed, tl(fixed))
    |> Enum.each(fn {a, b} -> assert a["end"] == b["start"] end)

    # 축척을 고쳤으면 클립도 거기에 맞춰야 한다. mode 가 없으면 fit_mode 가 :clips 를
    # 돌려주고 클립이 원본 8초 그대로 쓰여서, 자막만 줄고 영상은 안 줄어든다.
    assert Enum.all?(fixed, &(&1["mode"] == "tight"))

    # 어느 장면이 긴지는 그대로다.
    assert Enum.map(stale, & &1["target_sec"]) |> Enum.with_index() |> Enum.max() |> elem(1) ==
             Enum.map(fixed, & &1["target_sec"]) |> Enum.with_index() |> Enum.max() |> elem(1)
  end

  test "이미 맞으면 손대지 않는다" do
    ok = [%{"scene_id" => 1, "start" => 0.0, "end" => 6.0, "target_sec" => 6.0}]
    assert Assembly.fit_to_audio(ok, 5.0) == ok
    assert Assembly.fit_to_audio(nil, 5.0) == nil
    assert Assembly.fit_to_audio([], 5.0) == []
    # 길이를 모르면(0) 건드리지 않는다.
    assert Assembly.fit_to_audio(ok, 0) == ok
  end
end