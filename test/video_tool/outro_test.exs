defmodule VideoTool.OutroTest do
  use ExUnit.Case, async: false

  alias VideoTool.Assembly

  setup do
    dir = Path.join(to_string(:code.priv_dir(:video_tool)), "outro")
    File.mkdir_p!(dir)
    made = for n <- 1..3, do: Path.join(dir, "series_999_#{n}.mp4")
    Enum.each(made, &File.write!(&1, "x"))
    on_exit(fn -> Enum.each(made, &File.rm/1) end)
    :ok
  end

  # 같은 편을 다시 합성하면 끝이 바뀌면 안 된다 — 무작위로 고르지 않는다.
  test "프로젝트마다 다른 마무리를 쓰되 같은 편은 늘 같은 것을 쓴다" do
    picks = for pid <- 1..6, do: Assembly.outro_path(%{series_id: 999, id: pid})

    assert Enum.all?(picks, &is_binary/1)
    assert length(Enum.uniq(picks)) == 3
    assert Assembly.outro_path(%{series_id: 999, id: 1}) == Enum.at(picks, 0)
  end

  test "마무리 파일이 없는 시리즈는 그냥 넘어간다" do
    assert Assembly.outro_path(%{series_id: 998, id: 1}) == nil
    assert Assembly.outro_path(%{series_id: nil, id: 1}) == nil
  end

  # 도입도 같은 규칙으로 고른다. 폴더만 다르다.
  test "도입 영상도 돌아가며 쓴다" do
    assert Assembly.intro_path(%{series_id: 999, id: 1}) == nil
  end
end
