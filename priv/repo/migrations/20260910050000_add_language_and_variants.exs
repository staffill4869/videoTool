defmodule VideoTool.Repo.Migrations.AddLanguageAndVariants do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :language, :string, size: 10, null: false, default: "ko"
      # 다른 언어판이면 원본을 가리킨다. CLEAN 이미지를 원본과 공유한다.
      add :variant_of_id, references(:projects, on_delete: :nilify_all)
    end

    create index(:projects, [:variant_of_id])

    alter table(:series) do
      # 이 시리즈가 만들 언어들. 첫 번째가 원본이고 나머지는 언어판이다.
      add :languages, {:array, :string}, null: false, default: ["ko"]
    end
  end
end