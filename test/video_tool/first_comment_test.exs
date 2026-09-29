defmodule VideoTool.FirstCommentTest do
  use ExUnit.Case, async: true

  alias VideoTool.YouTube.Upload

  # 비공개 영상에 댓글을 달면 아무도 못 보는데 할당량(50유닛)만 나간다.
  # 하루 한도 10,000 에서 업로드 6편이 9,600 을 쓰므로 여유가 400뿐이다.
  test "비공개 영상에는 댓글을 달지 않는다" do
    assert %{ok: false, reason: "비공개"} =
             Upload.maybe_comment("token", "vid", %{privacy: "private"})
  end

  test "첫 댓글에 구독과 좋아요가 들어 있다" do
    text = Upload.first_comment()
    assert text =~ "구독"
    assert text =~ "좋아요"
    # 유튜브 댓글 한도는 10,000자다. 한참 밑이어야 정상이다.
    assert String.length(text) < 200
  end
end
