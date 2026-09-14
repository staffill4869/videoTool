defmodule VideoTool.Repo.Migrations.SeriesChannel do
  @moduledoc """
  시리즈마다 올릴 채널을 정한다.

  전에는 발행할 때 사람이 채널을 골랐다. 무인으로 돌리려면 "이 시리즈 것은 저 채널로" 가
  어딘가 적혀 있어야 한다. 시리즈에 붙이는 게 맞다 — 주제가 곧 채널이기 때문이다.

  비어 있으면 자동 발행하지 않는다. 되돌릴 수 없는 공개 행위의 기본값은 '안 함' 이다.
  """
  use Ecto.Migration

  def change do
    alter table(:series) do
      add :channel_slug, :string, null: false, default: ""
    end
  end
end
