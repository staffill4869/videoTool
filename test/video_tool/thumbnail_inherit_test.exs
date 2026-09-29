defmodule VideoTool.ThumbnailInheritTest do
  @moduledoc """
  합성을 다시 부르면 섬네일이 떨어지던 문제.

  2026-09-29: 올린 영상 22편 전부 섬네일이 없었다. 원인은 `assemble` 이 부를 때마다
  렌더 행을 새로 만드는 것이었다 — 붙여 둔 섬네일은 옛 행에 남고 발행은 최신 행을 본다.
  정상 흐름이 「합성 → check_video → 고침 → 재합성」 이라 거의 매번 이렇게 됐다.
  """
  use VideoTool.DataCase, async: false

  alias VideoTool.Assembly

  setup do
    dir = Path.join(System.tmp_dir!(), "thumb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "앞 렌더에 붙여 둔 섬네일을 물려받는다", %{dir: dir} do
    p = project()
    thumb = Path.join(dir, "thumb.jpg")
    File.write!(thumb, "x")

    render(p, thumb)

    assert Assembly.inherited_thumbnail(p.id) == thumb
  end

  test "섬네일 파일이 없어졌으면 물려받지 않는다 — 없는 경로를 들고 발행하면 업로드가 실패한다" do
    p = project()
    render(p, "/없는/경로/thumb.jpg")

    assert Assembly.inherited_thumbnail(p.id) == ""
  end

  test "붙인 적이 없으면 빈 문자열" do
    p = project()
    render(p, "")

    assert Assembly.inherited_thumbnail(p.id) == ""
  end

  test "여러 번 붙였으면 가장 최근 것" , %{dir: dir} do
    p = project()
    old = Path.join(dir, "old.jpg")
    new = Path.join(dir, "new.jpg")
    File.write!(old, "x")
    File.write!(new, "x")

    render(p, old)
    render(p, "")
    render(p, new)

    assert Assembly.inherited_thumbnail(p.id) == new
  end

  # ── fixtures ────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive])

  defp project do
    style = Repo.insert!(%VideoTool.Presets.StylePreset{slug: "s#{uniq()}", name: "그림체"})
    domain = Repo.insert!(%VideoTool.Presets.DomainPreset{slug: "d#{uniq()}", name: "장르"})

    voice =
      Repo.insert!(%VideoTool.Presets.Voice{
        slug: "v#{uniq()}",
        display_name: "목소리",
        provider: "elevenlabs",
        voice_id: "x"
      })

    Repo.insert!(%VideoTool.Projects.Project{
      title: "섬네일 시험 #{uniq()}",
      style_id: style.id,
      domain_id: domain.id,
      voice_id: voice.id
    })
  end

  defp render(p, thumb) do
    Repo.insert!(%VideoTool.Media.Render{
      project_id: p.id,
      kind: "final",
      aspect: "9:16",
      file_path: "/tmp/f-#{uniq()}.mp4",
      thumbnail_path: thumb
    })
  end
end
