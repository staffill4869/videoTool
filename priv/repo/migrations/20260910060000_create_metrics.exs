defmodule VideoCRM.Repo.Migrations.CreateMetrics do
  use Ecto.Migration

  def change do
    # 발행물의 성과. 같은 발행물을 여러 번 재는 시계열이다 —
    # 마지막 값만 덮어쓰면 "언제부터 늘었나" 를 못 본다.
    create table(:metrics) do
      add :publication_id, references(:publications, on_delete: :delete_all), null: false
      add :collected_at, :utc_datetime, null: false
      add :views, :bigint, null: false, default: 0
      add :likes, :bigint, null: false, default: 0
      add :comments, :bigint, null: false, default: 0
      add :shares, :bigint, null: false, default: 0
      # api = 플랫폼에서 긁어옴, manual = 사람이 화면 보고 입력
      add :source, :string, size: 20, null: false, default: "manual"
      add :note, :string, size: 200, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create index(:metrics, [:publication_id, :collected_at])
  end
end