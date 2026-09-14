defmodule VideoTool.Media.Asset do
  @moduledoc "Flow 가 뱉은 이미지·클립. 파일명은 내용과 무관하므로 phash 와 OCR 로 매핑한다."
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Projects.{Project, Scene}

  @kinds ~w(clean info clip)
  @statuses ~w(pending mapped approved rejected)

  schema "assets" do
    field :kind, :string
    field :source, :string, default: "flow"
    field :file_path, :string
    # Flow 원본 파일명. 내용과 무관하다 — 순서의 근거로 쓰지 말 것.
    field :source_filename, :string, default: ""
    field :phash, :string, default: ""
    # 클립 전용. 마지막 프레임 해시 — INFO 와 대조한다.
    field :phash_last, :string, default: ""
    field :width, :integer, default: 0
    field :height, :integer, default: 0
    field :duration_sec, :float
    field :fps, :float
    field :order_confidence, :float, default: 0.0
    field :status, :string, default: "pending"
    field :reject_reason, :string, default: ""

    belongs_to :project, Project
    belongs_to :scene, Scene

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(project_id scene_id kind source file_path source_filename phash phash_last
                      width height duration_sec fps order_confidence status reject_reason)a)
    |> validate_required([:project_id, :kind, :file_path])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
  end
end

defmodule VideoTool.Media.Narration do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Presets.Voice
  alias VideoTool.Projects.{Project, Script}

  schema "narrations" do
    field :file_path, :string
    field :duration_sec, :float, default: 0.0
    field :provider, :string, default: "higgsfield"
    field :provider_job_id, :string, default: ""
    # [[start, end], ...] 발화 구간
    field :silence_segments, VideoTool.JSONTerm, default: []
    # [[start, end], ...] 장면별 배정 결과
    field :scene_timing, VideoTool.JSONTerm, default: []
    field :measured_chars_per_sec, :float, default: 0.0

    belongs_to :project, Project
    belongs_to :script, Script
    belongs_to :voice, Voice

    timestamps(type: :utc_datetime)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(project_id script_id voice_id file_path duration_sec provider
                      provider_job_id silence_segments scene_timing measured_chars_per_sec)a)
    |> validate_required([:project_id, :script_id, :voice_id, :file_path])
  end
end

defmodule VideoTool.Media.Subtitle do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Media.Narration

  schema "subtitles" do
    field :index, :integer
    field :start_sec, :float
    field :end_sec, :float
    field :text, :string, default: ""
    field :is_edited, :boolean, default: false

    belongs_to :narration, Narration

    timestamps(type: :utc_datetime)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(narration_id index start_sec end_sec text is_edited)a)
    |> validate_required([:narration_id, :index, :start_sec, :end_sec])
    |> unique_constraint([:narration_id, :index])
  end
end

defmodule VideoTool.Media.Render do
  @moduledoc """
  완성본. 자막 없는 마스터(burn_subtitles: false)를 항상 함께 남긴다 —
  세로본은 하드번된 자막을 다시 쓸 수 없어 자막 없는 소스가 필요하다.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Media.{Narration, Render}
  alias VideoTool.Projects.Project

  schema "renders" do
    field :kind, :string, default: "final"
    field :aspect, :string, default: "16:9"
    field :file_path, :string
    field :thumbnail_path, :string, default: ""
    field :duration_sec, :float, default: 0.0
    field :ambient_volume, :float, default: 0.35
    field :burn_subtitles, :boolean, default: true
    field :settings, :map, default: %{}
    field :file_size, :integer, default: 0

    belongs_to :project, Project
    belongs_to :narration, Narration
    belongs_to :variant_of, Render

    timestamps(type: :utc_datetime)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(project_id narration_id variant_of_id kind aspect file_path
                      thumbnail_path duration_sec ambient_volume burn_subtitles
                      settings file_size)a)
    |> validate_required([:project_id, :file_path])
    |> validate_inclusion(:aspect, ["16:9", "9:16"])
  end
end

defmodule VideoTool.Media do
  @moduledoc "생성물 조회·저장."

  import Ecto.Query
  alias VideoTool.Repo
  alias VideoTool.Media.{Asset, Narration, Subtitle, Render}

  def list_assets(project_id, kind) do
    Repo.all(
      from a in Asset,
        where: a.project_id == ^project_id and a.kind == ^kind,
        order_by: [asc: a.scene_id, asc: a.id],
        preload: [:scene]
    )
  end

  @doc """
  장면 배정을 손으로 고친다.

  CLEAN 이 나오면 **이미지를 눈으로 봐야 한다.** dHash 배정은 "클립이 자기 이미지와
  맞는다" 는 뜻일 뿐이라, 장면 순서가 통째로 뒤섞여도 신뢰도는 높게 나온다
  (실측: 프로젝트 21·17·30·31 전부 섞였다).

  `order` 는 지금 자리(장면 번호) 의 나열이다. `[8, 2, 7, 1, 6, 5, 3, 4]` 는
  "1번 장면에는 지금 8번에 있는 그림을 써라" 는 뜻 — 콘택트 시트를 보면서 읽는 순서 그대로다.
  """
  def remap_scenes(project_id, kind, order) do
    assets = list_assets(project_id, kind) |> Enum.filter(& &1.scene_id)
    by_no = Map.new(assets, &{&1.scene.scene_no, &1})
    scenes = Map.new(assets, &{&1.scene.scene_no, &1.scene_id})
    n = map_size(by_no)

    cond do
      map_size(scenes) != length(assets) ->
        {:error, "한 장면에 #{kind} 자산이 여러 개입니다. 먼저 정리하세요."}

      length(order) != n ->
        {:error, "장면은 #{n}개인데 순서는 #{length(order)}개입니다."}

      Enum.sort(order) != Enum.sort(Map.keys(by_no)) ->
        {:error, "순서는 장면 번호를 한 번씩 전부 써야 합니다: #{inspect(Map.keys(by_no))}"}

      true ->
        {:ok, _} =
          Repo.transaction(fn ->
            # 장면 id 는 유일해야 하므로 한 번 떼었다 다시 붙인다.
            # 떼어낸 **그 구조체**를 다시 써야 한다. 원본 구조체에는 옛 scene_id 가 남아 있어
            # 제자리(1→1) 인 것은 Ecto 가 "바뀐 게 없다" 며 건너뛰고 nil 인 채로 둔다.
            nulled =
              Map.new(assets, fn a ->
                {a.scene.scene_no, Repo.update!(Ecto.Changeset.change(a, scene_id: nil))}
              end)

            order
            |> Enum.with_index(1)
            |> Enum.each(fn {from, to} ->
              Repo.update!(
                Ecto.Changeset.change(nulled[from], scene_id: scenes[to], order_confidence: 1.0)
              )
            end)
          end)

        {:ok, %{moved: Enum.count(Enum.with_index(order, 1), fn {f, t} -> f != t end), scenes: n}}
    end
  end

  @doc "단계별 개수. next/1 이 어디까지 왔는지 판단하는 근거."
  def asset_counts(project_id) do
    from(a in Asset,
      where: a.project_id == ^project_id,
      group_by: a.kind,
      select: {a.kind, count(a.id)}
    )
    |> Repo.all()
    |> Map.new()
    |> then(&Map.merge(%{"clean" => 0, "info" => 0, "clip" => 0}, &1))
  end

  @doc "Scene 에 매핑된 것만 센다 — 파일이 있어도 매핑이 안 됐으면 다음 단계로 갈 수 없다."
  # **장면 수**를 센다. 자산 개수를 세면 한 장면에 두 개가 붙었을 때 다른 장면이
  # 비어 있는데도 "다 찼다" 가 된다 — 실측: 클립 10개가 장면 7개에만 붙었는데
  # 8장면짜리 프로젝트가 완료로 판정돼 빈 장면을 못 채웠다.
  def mapped_counts(project_id) do
    from(a in Asset,
      where: a.project_id == ^project_id and not is_nil(a.scene_id),
      group_by: a.kind,
      select: {a.kind, count(a.scene_id, :distinct)}
    )
    |> Repo.all()
    |> Map.new()
    |> then(&Map.merge(%{"clean" => 0, "info" => 0, "clip" => 0}, &1))
  end

  def create_asset(attrs), do: %Asset{} |> Asset.changeset(attrs) |> Repo.insert()

  def update_asset(%Asset{} = asset, attrs),
    do: asset |> Asset.changeset(attrs) |> Repo.update()

  def latest_narration(project_id) do
    Repo.one(
      from n in Narration,
        where: n.project_id == ^project_id,
        order_by: [desc: n.id],
        limit: 1
    )
  end

  def create_narration(attrs), do: %Narration{} |> Narration.changeset(attrs) |> Repo.insert()

  def subtitles(narration_id),
    do: Repo.all(from s in Subtitle, where: s.narration_id == ^narration_id, order_by: s.index)

  def replace_subtitles(narration, rows) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.delete_all(from s in Subtitle, where: s.narration_id == ^narration.id)

    entries =
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {row, i} ->
        %{
          narration_id: narration.id,
          index: i,
          start_sec: row.start_sec,
          end_sec: row.end_sec,
          text: row.text,
          is_edited: false,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} = Repo.insert_all(Subtitle, entries)
    {:ok, count}
  end

  def renders(project_id),
    do: Repo.all(from r in Render, where: r.project_id == ^project_id, order_by: r.id)

  def latest_render(project_id, aspect) do
    Repo.one(
      from r in Render,
        where: r.project_id == ^project_id and r.aspect == ^aspect and r.burn_subtitles,
        order_by: [desc: r.id],
        limit: 1
    )
  end

  def create_render(attrs), do: %Render{} |> Render.changeset(attrs) |> Repo.insert()

  # ── 컨택트시트용 조회 ───────────────────────────────────────────

  @doc """
  장면별로 붙은 자산을 모은다: `%{scene_id => %{"clean" => asset, "info" => ..., "clip" => ...}}`.

  한 장면에 같은 kind 가 둘 붙어 있으면 신뢰도가 높은 쪽을 보여준다 —
  그런 상태 자체는 검증에서 문제로 잡힌다.
  """
  def assets_by_scene(project_id) do
    Repo.all(from a in Asset, where: a.project_id == ^project_id and not is_nil(a.scene_id))
    |> Enum.group_by(& &1.scene_id)
    |> Map.new(fn {scene_id, assets} ->
      {scene_id,
       assets
       |> Enum.group_by(& &1.kind)
       |> Map.new(fn {kind, list} -> {kind, Enum.max_by(list, & &1.order_confidence)} end)}
    end)
  end

  @doc "어느 장면에도 못 붙은 자산. 매핑이 실패한 것들이다."
  def unassigned_assets(project_id) do
    Repo.all(
      from a in Asset,
        where: a.project_id == ^project_id and is_nil(a.scene_id),
        order_by: a.source_filename
    )
  end

  def get_asset(id), do: Repo.get(Asset, id)

  @doc """
  사람이 직접 장면을 바꾼다. 신뢰도를 1.0 으로 올리고 approved 로 표시한다 —
  사람이 눈으로 확정한 것이 자동 매핑보다 확실하다.
  """
  def reassign(%Asset{} = asset, scene_id) do
    update_asset(asset, %{scene_id: scene_id, order_confidence: 1.0, status: "approved"})
  end

  @doc "매핑이 맞다고 확정. 신뢰도가 낮아도 사람이 봤으면 통과다."
  def approve(%Asset{} = asset) do
    update_asset(asset, %{order_confidence: 1.0, status: "approved"})
  end
end