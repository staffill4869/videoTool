defmodule VideoTool.Repo.Migrations.CreateSeries do
  use Ecto.Migration

  def change do
    # 반복 제작 설정. 한 번 정해두면 지정한 간격마다 프로젝트가 하나씩 생긴다.
    #
    # **제작만 자동이고 발행은 아니다.** 만들어진 프로젝트는 draft 로 대기하고,
    # 발행은 여전히 사람이 누를 때만 나간다 (설명서 7장: 자동 발행 스케줄러 금지).
    create table(:series) do
      add :name, :string, size: 120, null: false
      add :topic_brief, :text, null: false, default: ""
      # "계속 하나의 프롬프트로 찍어낸다" 의 그 프롬프트. 매 프로젝트에 그대로 들어간다.
      add :standing_prompt, :text, null: false, default: ""

      add :style_id, references(:style_presets, on_delete: :restrict), null: false
      add :domain_id, references(:domain_presets, on_delete: :restrict), null: false
      add :voice_id, references(:voices, on_delete: :restrict), null: false

      add :aspect, :string, size: 10, null: false, default: "16:9"
      add :target_sec, :integer, null: false, default: 60
      add :pipeline, :string, size: 10, null: false, default: "ai"
      add :output_folder, :string, size: 255, null: false, default: ""

      # 0 이면 자동 생성 안 함 (수동으로만 만든다)
      add :interval_minutes, :integer, null: false, default: 0
      # 기본 꺼짐 — 명시적으로 켜야 돈다
      add :active, :boolean, null: false, default: false
      # 대기 중인 프로젝트가 이만큼 쌓이면 더 만들지 않는다.
      # 없으면 에이전트가 대본을 안 쓰는 동안 빈 프로젝트가 무한히 쌓인다.
      add :max_pending, :integer, null: false, default: 3

      add :last_run_at, :utc_datetime
      add :next_run_at, :utc_datetime
      add :last_error, :text, null: false, default: ""
      add :created_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:series, [:active, :next_run_at])

    alter table(:projects) do
      add :series_id, references(:series, on_delete: :nilify_all)
      # 이 프로젝트에서만 쓸 프롬프트. %{"clean" => "...", "info" => nil}
      # 값이 있으면 템플릿 대신 이걸 쓴다 — 한 편만 다르게 가야 할 때가 생긴다.
      add :prompt_overrides, :map, null: false, default: %{}
      # 이 프로젝트에서만 덮어쓸 변수. 그림체 값을 한 편만 바꿔보고 싶을 때.
      add :variables, :map, null: false, default: %{}
    end

    create index(:projects, [:series_id])
  end
end