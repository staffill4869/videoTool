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
end
