defmodule VideoCRM.Repo.Migrations.AddPhashLastToAssets do
  use Ecto.Migration

  def change do
    # 클립은 해시가 두 개 필요하다. 첫 프레임은 CLEAN 과, 마지막 프레임은 INFO 와 대조한다.
    # 두 대조가 같은 장면을 가리켜야 매핑을 확정한다.
    alter table(:assets) do
      add :phash_last, :string, size: 32, null: false, default: ""
    end
  end
end