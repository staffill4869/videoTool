defmodule VideoTool.Repo.Migrations.AddSeriesSchedule do
  use Ecto.Migration

  def change do
    alter table(:series) do
      # 시각 예약. "09:00" 같은 로컬 시각을 담는다.
      # 비어 있으면 interval_minutes 로 돌고, 채워져 있으면 이쪽이 이긴다 —
      # 둘을 동시에 쓰면 언제 도는지 사람이 예측할 수 없다.
      add :run_times, {:array, :string}, null: false, default: []
      # 도는 요일. 1=월 … 7=일. 비어 있으면 매일.
      add :run_days, {:array, :integer}, null: false, default: []
    end
  end
end
