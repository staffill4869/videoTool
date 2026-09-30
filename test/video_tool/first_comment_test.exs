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

  # 우리는 안 막는다. 유튜브가 400 으로 직접 막고, 계정을 정지시키지는 않는다.
  # 2026-09-29 실측: 세 채널 각 6편, 총 18편이 전부 올라갔다 — 할당량은 벽이 아니었다.
  test "하루 상한은 기본으로 풀려 있다" do
    assert VideoTool.Publishing.daily_cap() == 0
  end
end
