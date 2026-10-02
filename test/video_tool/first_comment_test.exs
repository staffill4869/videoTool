defmodule VideoTool.FirstCommentTest do
  use ExUnit.Case, async: true

  alias VideoTool.YouTube.Upload

  # 비공개 영상에 댓글을 달면 아무도 못 보는데 할당량(50유닛)만 나간다.
  # 하루 한도 10,000 에서 업로드 6편이 9,600 을 쓰므로 여유가 400뿐이다.
  test "비공개 영상에는 댓글을 달지 않는다" do
    assert %{ok: false, reason: "비공개"} =
             Upload.maybe_comment("token", "vid", %{privacy: "private"})
  end

  # 채널마다 하고 싶은 말이 다르다. 영양제는 프로필을 눌러 보라고 하고,
  # 지원사업은 그럴 이유가 없다. 비워 두면 기본 문구로 떨어진다.
  test "채널에 첫 댓글이 적혀 있으면 그걸 쓴다" do
    assert Upload.first_comment(%{first_comment: "프로필을 눌러 보세요"}) ==
             "프로필을 눌러 보세요"

    assert Upload.first_comment(%{first_comment: "   "}) == Upload.first_comment()
    assert Upload.first_comment(%{first_comment: ""}) == Upload.first_comment()
  end

  test "첫 댓글에 구독과 좋아요가 들어 있다" do
    text = Upload.first_comment()
    assert text =~ "구독"
    assert text =~ "좋아요"
    # 유튜브 댓글 한도는 10,000자다. 한참 밑이어야 정상이다.
    assert String.length(text) < 200
  end

  test "비공개 영상에는 좋아요도 누르지 않는다" do
    assert %{ok: false, reason: "비공개"} =
             Upload.maybe_like("token", "vid", %{privacy: "private"})
  end

  # 유튜브는 업로드를 거절하지 않고 **노출을 끊는다.**
  # 실측(2026-09-30, 영양제 채널): 6번째까지 1,200회대, 7번째부터 한 자릿수.
  # 400 을 안 받았다고 괜찮은 게 아니다 — 거절은 보이지만 노출 차단은 안 보인다.
  # 값 자체는 운영 중에 바꾼다 (DAILY_PUBLISH_CAP). 그래서 숫자를 박지 않는다 —
  # 실제로 3 으로 낮춘 뒤 이 테스트만 빨갛게 남아 있었다.
  # 지켜야 할 것은 **상한이 꺼져 있지 않다(0 이 아니다)** 는 것이다.
  test "하루 상한이 걸려 있다" do
    cap = VideoTool.Publishing.daily_cap()
    assert is_integer(cap) and cap > 0, "하루 상한이 꺼져 있습니다 (cap=#{cap})"
  end
end
