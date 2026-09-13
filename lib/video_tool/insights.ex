defmodule VideoTool.Insights.Metric do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Publishing.Publication

  schema "metrics" do
    field :collected_at, :utc_datetime
    field :views, :integer, default: 0
    field :likes, :integer, default: 0
    field :comments, :integer, default: 0
    field :shares, :integer, default: 0
    field :source, :string, default: "manual"
    field :note, :string, default: ""

    belongs_to :publication, Publication

    timestamps(type: :utc_datetime)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(publication_id collected_at views likes comments shares source note)a)
    |> validate_required([:publication_id])
    |> validate_inclusion(:source, ["api", "manual"])
    |> validate_number(:views, greater_than_or_equal_to: 0)
  end
end

defmodule VideoTool.Insights do
  @moduledoc """
  발행물 성과 집계.

  같은 발행물을 여러 번 재서 시계열로 쌓는다 — 마지막 값만 덮어쓰면
  "언제부터 늘었나" 를 못 본다. 집계는 **발행물마다 가장 최근 측정치**를 쓴다.

  아직 플랫폼 API 로 긁어오지 않는다(OAuth 가 붙어야 한다). 그때까지는 사람이
  화면을 보고 넣는다 — 그래도 집계·비교는 지금부터 된다.
  """

  import Ecto.Query

  alias VideoTool.Insights.Metric
  alias VideoTool.Publishing.Publication
  alias VideoTool.Repo
  alias VideoTool.YouTube

  def record(publication_id, attrs) do
    %Metric{}
    |> Metric.changeset(
      Map.merge(
        %{
          "publication_id" => publication_id,
          "collected_at" => DateTime.utc_now() |> DateTime.truncate(:second)
        },
        stringify(attrs)
      )
    )
    |> Repo.insert()
  end

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  @doc "발행물마다 가장 최근 측정치 하나씩."
  def latest_per_publication do
    newest =
      from m in Metric,
        select: %{publication_id: m.publication_id, collected_at: max(m.collected_at)},
        group_by: m.publication_id

    from(m in Metric,
      join: n in subquery(newest),
      on: m.publication_id == n.publication_id and m.collected_at == n.collected_at,
      preload: [publication: [:channel, :project]]
    )
    |> Repo.all()
    |> Enum.uniq_by(& &1.publication_id)
  end

  @doc "전체 합계와 채널별·프로젝트별 쪼갬."
  def dashboard do
    rows = latest_per_publication()

    %{
      totals: sum(rows),
      by_channel:
        rows
        |> Enum.group_by(& &1.publication.channel.slug)
        |> Enum.map(fn {slug, group} -> Map.put(sum(group), :key, slug) end)
        |> Enum.sort_by(& &1.views, :desc),
      by_project:
        rows
        |> Enum.group_by(& &1.publication.project.title)
        |> Enum.map(fn {title, group} -> Map.put(sum(group), :key, title) end)
        |> Enum.sort_by(& &1.views, :desc),
      by_language:
        rows
        |> Enum.group_by(& &1.publication.project.language)
        |> Enum.map(fn {lang, group} -> Map.put(sum(group), :key, lang) end)
        |> Enum.sort_by(& &1.views, :desc),
      # Ecto 구조체를 그대로 내보내면 JSON 인코더가 없어서 터진다. 평범한 맵으로 눕힌다.
      rows: rows |> Enum.sort_by(& &1.views, :desc) |> Enum.map(&row/1),
      measured: length(rows)
    }
  end

  defp row(m) do
    %{
      publication_id: m.publication_id,
      project: m.publication.project.title,
      language: m.publication.project.language,
      channel: m.publication.channel.slug,
      url: m.publication.external_url,
      views: m.views,
      likes: m.likes,
      comments: m.comments,
      shares: m.shares,
      collected_at: m.collected_at,
      source: m.source
    }
  end

  defp sum(rows) do
    %{
      count: length(rows),
      views: Enum.sum(Enum.map(rows, & &1.views)),
      likes: Enum.sum(Enum.map(rows, & &1.likes)),
      comments: Enum.sum(Enum.map(rows, & &1.comments)),
      shares: Enum.sum(Enum.map(rows, & &1.shares))
    }
  end

  @doc """
  유튜브 공개 영상의 통계를 긁어와 기록한다.

  API 키만 있으면 된다 — 업로드용 OAuth 를 기다릴 필요가 없다.
  비공개·삭제된 영상은 응답에서 빠지는데, 그건 오류가 아니라 정보다.
  조용히 0 으로 기록하지 않고 `missing` 으로 돌려준다 — 0 으로 적으면
  "조회수가 0" 과 "못 읽었다" 를 구분할 수 없게 된다.
  """
  def collect_youtube do
    publications =
      measurable_publications()
      |> Enum.filter(&(&1.channel.platform == "youtube"))
      |> Enum.map(&{&1, YouTube.video_id(&1.external_id) || YouTube.video_id(&1.external_url)})

    {known, unknown} = Enum.split_with(publications, fn {_p, id} -> id end)

    with {:ok, stats} <- YouTube.stats(Enum.map(known, &elem(&1, 1))) do
      {recorded, missing} =
        Enum.reduce(known, {[], []}, fn {publication, video_id}, {ok, miss} ->
          case Map.get(stats, video_id) do
            nil ->
              {ok, [%{publication_id: publication.id, video_id: video_id} | miss]}

            values ->
              {:ok, _} = record(publication.id, Map.put(values, :source, "api"))
              {[%{publication_id: publication.id, video_id: video_id} | ok], miss}
          end
        end)

      {:ok,
       %{
         recorded: length(recorded),
         missing: missing,
         no_video_id: Enum.map(unknown, fn {p, _} -> p.id end)
       }}
    end
  end

  @doc "한 발행물의 측정 이력 (오래된 것부터). 증가 추이를 보는 용도."
  def history(publication_id) do
    Repo.all(
      from m in Metric,
        where: m.publication_id == ^publication_id,
        order_by: m.collected_at
    )
  end

  @doc "발행 이력이 있는 것 목록. 측정치를 넣을 대상을 고를 때 쓴다."
  def measurable_publications do
    Repo.all(
      from p in Publication,
        where: p.status == "published",
        order_by: [desc: p.published_at],
        preload: [:channel, :project]
    )
  end

  @doc """
  이 시스템 밖에서 이미 올린 영상을 등록한다.

  발행 기능이 아직 없으므로 지금 올라간 영상은 전부 손으로 올린 것이다.
  등록해두지 않으면 집계할 대상이 하나도 없다.
  """
  def register_published(project, channel, render, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    params = %{
      project_id: project.id,
      channel_id: channel.id,
      render_id: render && render.id,
      status: "published",
      title: attrs["title"] || project.title,
      external_url: attrs["external_url"] || "",
      external_id: attrs["external_id"] || "",
      privacy: attrs["privacy"] || "public",
      requested_at: now,
      published_at: parse_time(attrs["published_at"]) || now
    }

    # render 가 없을 수 있다. nil 을 get_by 에 넣으면 Ecto 가 막으므로 is_nil 로 쓴다.
    render_id = render && render.id

    query =
      from p in Publication,
        where: p.project_id == ^project.id and p.channel_id == ^channel.id

    existing =
      if render_id do
        Repo.one(from p in query, where: p.render_id == ^render_id)
      else
        Repo.one(from p in query, where: is_nil(p.render_id))
      end

    case existing do
      nil -> %Publication{}
      row -> row
    end
    |> Publication.changeset(params)
    |> Repo.insert_or_update()
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end
end