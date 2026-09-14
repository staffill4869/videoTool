defmodule VideoTool.Publishing.Channel do
  @moduledoc """
  업로드 대상 계정.

  실제 OAuth 토큰은 여기 넣지 않는다 — `credential_ref` 만 두고 토큰은 OS 자격증명
  저장소에 있다. DB 파일이 유출돼도 계정이 털리지 않게 하기 위해서다.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @platforms ~w(youtube instagram)

  schema "channels" do
    field :platform, :string
    field :slug, :string
    field :display_name, :string
    field :account_id, :string, default: ""
    field :credential_ref, :string, default: ""
    field :token_expires_at, :utc_datetime
    field :default_privacy, :string, default: "private"
    field :default_category, :string, default: "27"
    field :default_language, :string, default: "ko"
    field :title_pattern, :string, default: "{title}"
    field :description_pattern, :string, default: "{description}"
    field :default_hashtags, {:array, :string}, default: []
    field :aspect_required, :string, default: "any"
    field :max_duration_sec, :integer, default: 0
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def platforms, do: @platforms

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(platform slug display_name account_id credential_ref token_expires_at
                      default_privacy default_category default_language title_pattern
                      description_pattern default_hashtags aspect_required max_duration_sec
                      is_active)a)
    |> validate_required([:platform, :slug, :display_name])
    |> validate_inclusion(:platform, @platforms)
    |> validate_inclusion(:aspect_required, ["16:9", "9:16", "any"])
    |> validate_inclusion(:default_privacy, ["private", "unlisted", "public"])
    |> unique_constraint(:slug)
  end

  @doc "토큰 만료 여부. 만료됐으면 reauth 가 필요하다."
  def token_valid?(%__MODULE__{token_expires_at: nil}), do: false

  def token_valid?(%__MODULE__{token_expires_at: exp}),
    do: DateTime.compare(exp, DateTime.utc_now()) == :gt
end

defmodule VideoTool.Publishing.Publication do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias VideoTool.Media.Render
  alias VideoTool.Projects.Project
  alias VideoTool.Publishing.Channel

  @statuses ~w(draft uploading processing published failed)

  schema "publications" do
    field :status, :string, default: "draft"
    field :title, :string, default: ""
    field :description, :string, default: ""
    field :hashtags, {:array, :string}, default: []
    field :privacy, :string, default: "private"
    field :scheduled_at, :utc_datetime
    field :external_id, :string, default: ""
    field :external_url, :string, default: ""
    field :thumbnail_uploaded, :boolean, default: false
    field :captions_uploaded, :boolean, default: false
    field :error, :string, default: ""
    field :requested_at, :utc_datetime
    field :published_at, :utc_datetime

    belongs_to :project, Project
    belongs_to :channel, Channel
    belongs_to :render, Render

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, ~w(project_id channel_id render_id status title description hashtags
                      privacy scheduled_at external_id external_url thumbnail_uploaded
                      captions_uploaded error requested_at published_at)a)
    # render_id 는 비워둘 수 있다 — 밖에서 손으로 올린 영상은 우리 렌더가 없다.
    |> validate_required([:project_id, :channel_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:privacy, ["private", "unlisted", "public"])
    |> unique_constraint([:project_id, :channel_id, :render_id],
      message: "이 렌더는 이미 이 채널에 발행 기록이 있습니다"
    )
  end
end

defmodule VideoTool.Publishing do
  @moduledoc """
  발행. 자동으로 실행되지 않는다 — `publish/3` 은 `confirm: true` 를 명시적으로 받아야 하고,
  그 값은 사용자가 발행을 지시했을 때만 전달된다.
  """

  import Ecto.Query
  alias VideoTool.{Media, Repo}
  alias VideoTool.Jobs
  alias VideoTool.Publishing.{Channel, Publication}

  # 플랫폼 제약. 넘으면 잘라내고 경고를 돌려준다.
  @limits %{
    "youtube" => %{title: 100, description: 5000, hashtags: 60},
    "instagram" => %{title: 200, description: 2200, hashtags: 30}
  }

  def list_channels do
    Repo.all(from c in Channel, where: c.is_active, order_by: c.slug)
  end

  def update_channel(%Channel{} = channel, attrs),
    do: channel |> Channel.changeset(attrs) |> Repo.update()

  @doc """
  발행 채널을 하나 만든다.

  `credential_ref` 는 **행마다 달라야 한다.** 토큰이 그 경로에 저장되므로 두 행이 같은 ref 를
  쓰면 같은 유튜브 채널로 올라간다 — 실제로 yt-main·yt-shorts 가 그랬다.
  """
  def create_channel(attrs) do
    attrs =
      Map.put_new_lazy(attrs, :credential_ref, fn ->
        "videoCRM/#{attrs[:platform]}/#{attrs[:slug]}"
      end)

    %Channel{} |> Channel.changeset(attrs) |> Repo.insert()
  end

  def fetch_channel(slug) do
    case Repo.get_by(Channel, slug: slug) do
      nil -> {:error, "채널 '#{slug}' 을(를) 찾을 수 없습니다"}
      c -> {:ok, c}
    end
  end

  @doc """
  에이전트가 작성한 제목·설명을 저장만 한다. 발행하지 않는다.
  플랫폼 제약을 여기서 검사해 잘라내고 무엇이 잘렸는지 돌려준다.
  """
  def save_publish_meta(project, channel, render, attrs) do
    limits = Map.fetch!(@limits, channel.platform)
    hashtags = attrs["hashtags"] || channel.default_hashtags

    {title, w1} = clamp(attrs["title"] || "", limits.title, "제목")
    {description, w2} = clamp(attrs["description"] || "", limits.description, "설명")
    {hashtags, w3} = clamp_list(hashtags, limits.hashtags)

    params = %{
      project_id: project.id,
      channel_id: channel.id,
      render_id: render.id,
      status: "draft",
      title: title,
      description: description,
      hashtags: hashtags,
      # 채널이 private 이면 무조건 private 이다. 무인 루프가 실수로 public 을 넣어도
      # 공개로 나가지 않게 **코드에서** 막는다 — 프롬프트 지시만으로는 막을 수 없다.
      # 공개로 바꾸려면 채널의 default_privacy 를 사람이 먼저 바꿔야 한다.
      privacy: resolve_privacy(channel, attrs["privacy"]),
      scheduled_at: attrs["scheduled_at"]
    }

    existing =
      Repo.get_by(Publication,
        project_id: project.id,
        channel_id: channel.id,
        render_id: render.id
      )

    changeset =
      case existing do
        nil -> Publication.changeset(%Publication{}, params)
        row -> Publication.changeset(row, params)
      end

    with {:ok, publication} <- Repo.insert_or_update(changeset) do
      {:ok, publication, Enum.reject([w1, w2, w3], &is_nil/1)}
    end
  end

  defp clamp(text, limit, label) do
    if String.length(text) > limit do
      {String.slice(text, 0, limit), "#{label}이 #{limit}자를 넘어 잘렸습니다"}
    else
      {text, nil}
    end
  end

  defp clamp_list(list, limit) do
    if length(list) > limit do
      {Enum.take(list, limit), "해시태그가 #{limit}개를 넘어 잘렸습니다"}
    else
      {list, nil}
    end
  end

  @doc """
  발행 전 최종 확인. 하나라도 걸리면 발행하지 않는다.
  되돌리기 어려운 공개 행위라서 검사를 통과 못 하면 그냥 멈춘다.
  """
  def precheck(project, channel, render) do
    final = Jobs.latest_validation(project.id, "final")

    checks = [
      {final != nil and final.passed, "최종 검증(final)이 통과되지 않았습니다"},
      {token_usable?(channel),
       "채널 '#{channel.slug}' 토큰이 만료됐습니다. reauth 를 먼저 실행하세요"},
      {channel.aspect_required in ["any", render.aspect],
       "채널은 #{channel.aspect_required} 를 요구하는데 렌더는 #{render.aspect} 입니다"},
      {channel.max_duration_sec == 0 or render.duration_sec <= channel.max_duration_sec,
       "길이 #{Float.round(render.duration_sec, 1)}초가 채널 상한 #{channel.max_duration_sec}초를 넘습니다"},
      {not already_published?(project, channel, render),
       "같은 렌더가 이미 이 채널에 발행됐습니다 (중복 발행 차단)"}
    ]

    case Enum.reject(checks, fn {ok, _} -> ok end) do
      [] -> :ok
      failures -> {:error, Enum.map(failures, fn {_, msg} -> msg end)}
    end
  end

  # 만료 컬럼만 보고 막으면 refresh_token 이 멀쩡한데도 사람을 부르게 된다.
  # access_token/1 이 만료 시 알아서 갱신하므로 갱신까지 시켜 보고 판정한다.
  # (refresh_token 이 없거나 폐기됐으면 여기서 여전히 걸린다 — 그때는 진짜 reauth 가 필요하다)
  defp token_usable?(%Channel{platform: "youtube"} = channel) do
    Channel.token_valid?(channel) or
      match?({:ok, _}, VideoTool.Publishing.GoogleOAuth.access_token(channel))
  end

  defp token_usable?(channel), do: Channel.token_valid?(channel)

  # 채널이 private 이면 무조건 private 이다. 무인 루프가 실수로 public 을 넣어도
  # 공개로 나가지 않게 **코드에서** 막는다 — 프롬프트 지시만으로는 막을 수 없다.
  # 공개로 바꾸려면 채널의 default_privacy 를 사람이 먼저 바꿔야 한다.
  defp resolve_privacy(%Channel{default_privacy: "private"}, _asked), do: "private"
  defp resolve_privacy(channel, asked), do: asked || channel.default_privacy

  defp already_published?(project, channel, render) do
    Repo.exists?(
      from p in Publication,
        where:
          p.project_id == ^project.id and p.channel_id == ^channel.id and
            p.render_id == ^render.id and p.status == "published"
    )
  end

  @doc """
  실제 업로드. 아직 구현되지 않았다 — 유튜브 OAuth 는 5주차, 인스타는 6주차다.
  구현 전까지는 성공한 척하지 않고 명시적으로 실패를 돌려준다.
  """
  def publish(_project, _channel, _render, confirm) when confirm != true do
    {:error, "publish 는 confirm: true 를 명시적으로 받아야 실행됩니다"}
  end

  def publish(project, channel, render, true) do
    with :ok <- precheck(project, channel, render),
         {:ok, publication} <- draft_for(project, channel, render) do
      do_publish(publication, project, channel, render)
    end
  end

  defp draft_for(project, channel, render) do
    case Repo.get_by(Publication,
           project_id: project.id,
           channel_id: channel.id,
           render_id: render.id
         ) do
      nil ->
        {:error, "발행 초안이 없습니다. save_publish_meta 로 제목·설명을 먼저 저장하세요."}

      publication ->
        {:ok, Repo.preload(publication, [:project, :channel, :render])}
    end
  end

  defp do_publish(publication, project, channel, render) do
    {:ok, publication} = mark(publication, %{status: "uploading", error: ""})

    case upload(publication, project, channel, render) do
      {:ok, result} ->
        {:ok, updated} =
          mark(publication, %{
            status: "published",
            external_id: result.video_id,
            external_url: result.url,
            thumbnail_uploaded: result.thumbnail.ok,
            captions_uploaded: result.captions.ok,
            published_at: DateTime.utc_now() |> DateTime.truncate(:second),
            error: ""
          })

        {:ok,
         %{
           publication_id: updated.id,
           status: updated.status,
           external_url: updated.external_url,
           steps: %{
             upload: "ok",
             thumbnail: step(result.thumbnail),
             captions: step(result.captions)
           }
         }}

      {:error, reason} ->
        {:ok, _} = mark(publication, %{status: "failed", error: to_string(reason)})
        {:error, reason}
    end
  end

  defp upload(publication, project, channel, render) do
    case channel.platform do
      "youtube" ->
        VideoTool.YouTube.Upload.publish(publication, project, channel, render)

      "instagram" ->
        {:error,
         "인스타는 아직 구현되지 않았습니다 (6주차). 바이트를 직접 못 올려서 공개 URL 호스팅과 " <>
           "Meta 앱 검수가 먼저 필요합니다."}

      other ->
        {:error, "모르는 플랫폼: #{other}"}
    end
  end

  defp mark(publication, attrs), do: publication |> Publication.changeset(attrs) |> Repo.update()

  defp step(%{ok: true}), do: "ok"
  defp step(%{reason: reason}), do: reason

  def publications(project_id) do
    Repo.all(
      from p in Publication,
        where: p.project_id == ^project_id,
        order_by: [desc: p.id],
        preload: [:channel, :render]
    )
  end

  def get_publication(id) do
    case Repo.get(Publication, id) |> Repo.preload([:channel, :render]) do
      nil -> {:error, "발행 기록 #{id} 을(를) 찾을 수 없습니다"}
      p -> {:ok, p}
    end
  end

  @doc "채널이 요구하는 화면비에 맞는 렌더를 고른다."
  def render_for(project_id, %Channel{aspect_required: "any"}),
    do: Media.latest_render(project_id, "16:9")

  def render_for(project_id, %Channel{aspect_required: aspect}),
    do: Media.latest_render(project_id, aspect)
end