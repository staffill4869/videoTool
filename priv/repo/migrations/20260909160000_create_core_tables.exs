defmodule VideoCRM.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    # ── [A] 프리셋 ───────────────────────────────────────────────
    create table(:style_presets) do
      add :name, :string, size: 50, null: false
      add :slug, :string, size: 50, null: false
      add :global_style, :text, null: false, default: ""
      add :clean_rules, :text, null: false, default: ""
      add :camera_rules, :text, null: false, default: ""
      add :asset_definitions, :text, null: false, default: ""
      add :default_aspect, :string, size: 10, null: false, default: "16:9"
      add :is_active, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:style_presets, [:slug])

    create table(:domain_presets) do
      add :name, :string, size: 50, null: false
      add :slug, :string, size: 50, null: false
      add :info_rules, :text, null: false, default: ""
      add :element_list, :text, null: false, default: ""
      add :color_semantics, :map, null: false, default: %{}
      add :video_topic_rules, :text, null: false, default: ""
      add :is_active, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:domain_presets, [:slug])

    create table(:voices) do
      add :provider, :string, size: 20, null: false, default: "higgsfield"
      add :voice_id, :string, size: 64, null: false
      add :variant, :string, size: 20, null: false, default: "elevenlabs"
      add :display_name, :string, size: 50, null: false
      add :slug, :string, size: 50, null: false
      add :lang, :string, size: 10, null: false, default: "ko"
      add :chars_per_sec, :float, null: false, default: 5.9
      add :sample_count, :integer, null: false, default: 0
      add :is_default, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:voices, [:slug])

    create table(:prompt_templates) do
      add :stage, :string, size: 10, null: false
      add :body, :text, null: false, default: ""
      add :version, :integer, null: false, default: 1
      add :is_active, :boolean, null: false, default: true
      add :notes, :text, null: false, default: ""
      timestamps(type: :utc_datetime)
    end

    create unique_index(:prompt_templates, [:stage, :version])

    # ── [B] 프로젝트 · 대본 ──────────────────────────────────────
    create table(:projects) do
      add :title, :string, size: 120, null: false
      add :topic, :string, size: 200, null: false, default: ""
      add :target_sec, :integer, null: false, default: 60
      add :aspect, :string, size: 10, null: false, default: "16:9"
      add :style_id, references(:style_presets, on_delete: :restrict), null: false
      add :domain_id, references(:domain_presets, on_delete: :restrict), null: false
      add :voice_id, references(:voices, on_delete: :restrict), null: false
      add :pipeline, :string, size: 10, null: false, default: "ai"
      add :status, :string, size: 20, null: false, default: "draft"
      add :work_dir, :string, size: 255, null: false, default: ""
      add :output_folder, :string, size: 255, null: false, default: ""
      timestamps(type: :utc_datetime)
    end

    create index(:projects, [:style_id])
    create index(:projects, [:domain_id])
    create index(:projects, [:voice_id])

    create table(:scripts) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :version, :integer, null: false, default: 1
      add :raw_text, :text, null: false, default: ""
      add :tts_text, :text, null: false, default: ""
      add :estimated_sec, :float, null: false, default: 0.0
      add :actual_sec, :float
      add :source, :string, size: 20, null: false, default: "draft"
      add :is_active, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:scripts, [:project_id, :version])
    create index(:scripts, [:project_id, :is_active])

    create table(:scenes) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :scene_no, :integer, null: false
      add :target_sec, :float, null: false, default: 0.0
      add :purpose, :string, size: 20, null: false, default: "setup"
      add :shot_prompt, :text, null: false, default: ""
      add :info_instruction, :text, null: false, default: ""
      add :camera_plan, :map, null: false, default: %{}
      add :use_fast_zoom, :boolean, null: false, default: false
      add :expected_labels, {:array, :string}, null: false, default: []
      timestamps(type: :utc_datetime)
    end

    create unique_index(:scenes, [:project_id, :scene_no])

    create table(:script_segments) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :scene_id, references(:scenes, on_delete: :delete_all), null: false
      add :text, :text, null: false, default: ""
      add :order, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:script_segments, [:script_id, :scene_id])
    create index(:script_segments, [:scene_id])

    create table(:allowed_facts) do
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :kind, :string, size: 10, null: false, default: "number"
      add :value, :string, size: 80, null: false
      add :note, :string, size: 200, null: false, default: ""
      timestamps(type: :utc_datetime)
    end

    create index(:allowed_facts, [:script_id])

    # ── [C] 생성물 ───────────────────────────────────────────────
    create table(:assets) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :scene_id, references(:scenes, on_delete: :nilify_all)
      add :kind, :string, size: 20, null: false
      add :source, :string, size: 20, null: false, default: "flow"
      add :file_path, :string, size: 255, null: false
      add :source_filename, :string, size: 255, null: false, default: ""
      add :phash, :string, size: 32, null: false, default: ""
      add :width, :integer, null: false, default: 0
      add :height, :integer, null: false, default: 0
      add :duration_sec, :float
      add :fps, :float
      add :order_confidence, :float, null: false, default: 0.0
      add :status, :string, size: 20, null: false, default: "pending"
      add :reject_reason, :string, size: 200, null: false, default: ""
      timestamps(type: :utc_datetime)
    end

    create index(:assets, [:project_id, :kind, :scene_id])

    create table(:narrations) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :script_id, references(:scripts, on_delete: :restrict), null: false
      add :voice_id, references(:voices, on_delete: :restrict), null: false
      add :file_path, :string, size: 255, null: false
      add :duration_sec, :float, null: false, default: 0.0
      add :provider, :string, size: 20, null: false, default: "higgsfield"
      add :provider_job_id, :string, size: 64, null: false, default: ""
      add :silence_segments, :map, null: false, default: fragment("'[]'::jsonb")
      add :scene_timing, :map, null: false, default: fragment("'[]'::jsonb")
      add :measured_chars_per_sec, :float, null: false, default: 0.0
      timestamps(type: :utc_datetime)
    end

    create index(:narrations, [:project_id])

    create table(:subtitles) do
      add :narration_id, references(:narrations, on_delete: :delete_all), null: false
      add :index, :integer, null: false
      add :start_sec, :float, null: false
      add :end_sec, :float, null: false
      add :text, :text, null: false, default: ""
      add :is_edited, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:subtitles, [:narration_id, :index])

    create table(:renders) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :narration_id, references(:narrations, on_delete: :nilify_all)
      add :variant_of_id, references(:renders, on_delete: :nilify_all)
      add :kind, :string, size: 20, null: false, default: "final"
      add :aspect, :string, size: 10, null: false, default: "16:9"
      add :file_path, :string, size: 255, null: false
      add :thumbnail_path, :string, size: 255, null: false, default: ""
      add :duration_sec, :float, null: false, default: 0.0
      add :ambient_volume, :float, null: false, default: 0.35
      add :burn_subtitles, :boolean, null: false, default: true
      add :settings, :map, null: false, default: %{}
      add :file_size, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:renders, [:project_id])

    # ── [D] 작업 이력 ────────────────────────────────────────────
    create table(:generation_jobs) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :asset_id, references(:assets, on_delete: :nilify_all)
      add :provider, :string, size: 20, null: false
      add :model, :string, size: 60, null: false, default: ""
      add :external_job_id, :string, size: 64, null: false, default: ""
      add :status, :string, size: 20, null: false, default: "pending"
      add :result_url, :string, null: false, default: ""
      add :credits, :decimal, precision: 8, scale: 2, null: false, default: 0
      add :error, :text, null: false, default: ""
      add :requested_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:generation_jobs, [:project_id])

    create table(:ingest_jobs) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :watched_path, :string, size: 255, null: false, default: ""
      add :detected_file, :string, size: 255, null: false, default: ""
      add :file_mtime, :utc_datetime
      add :extracted_count, :integer, null: false, default: 0
      add :mapped_count, :integer, null: false, default: 0
      add :method, :string, size: 20, null: false, default: "phash"
      add :status, :string, size: 20, null: false, default: "pending"
      add :log, :text, null: false, default: ""
      timestamps(type: :utc_datetime)
    end

    create index(:ingest_jobs, [:project_id])

    create table(:validations) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :stage, :string, size: 20, null: false
      add :passed, :boolean, null: false, default: false
      add :checks, :map, null: false, default: %{}
      add :problems, :map, null: false, default: fragment("'[]'::jsonb")
      timestamps(type: :utc_datetime)
    end

    create index(:validations, [:project_id, :stage])

    # ── [E] 발행 ─────────────────────────────────────────────────
    create table(:channels) do
      add :platform, :string, size: 20, null: false
      add :slug, :string, size: 50, null: false
      add :display_name, :string, size: 80, null: false
      add :account_id, :string, size: 64, null: false, default: ""
      add :credential_ref, :string, size: 120, null: false, default: ""
      add :token_expires_at, :utc_datetime
      add :default_privacy, :string, size: 20, null: false, default: "private"
      add :default_category, :string, size: 20, null: false, default: "27"
      add :default_language, :string, size: 10, null: false, default: "ko"
      add :title_pattern, :string, size: 200, null: false, default: "{title}"
      add :description_pattern, :text, null: false, default: "{description}"
      add :default_hashtags, {:array, :string}, null: false, default: []
      add :aspect_required, :string, size: 10, null: false, default: "any"
      add :max_duration_sec, :integer, null: false, default: 0
      add :is_active, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:channels, [:slug])

    create table(:publications) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :channel_id, references(:channels, on_delete: :restrict), null: false
      add :render_id, references(:renders, on_delete: :restrict), null: false
      add :status, :string, size: 20, null: false, default: "draft"
      add :title, :string, size: 200, null: false, default: ""
      add :description, :text, null: false, default: ""
      add :hashtags, {:array, :string}, null: false, default: []
      add :privacy, :string, size: 20, null: false, default: "private"
      add :scheduled_at, :utc_datetime
      add :external_id, :string, size: 64, null: false, default: ""
      add :external_url, :string, null: false, default: ""
      add :thumbnail_uploaded, :boolean, null: false, default: false
      add :captions_uploaded, :boolean, null: false, default: false
      add :error, :text, null: false, default: ""
      add :requested_at, :utc_datetime
      add :published_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:publications, [:project_id, :channel_id, :render_id])
    create index(:publications, [:project_id, :status])
  end
end
