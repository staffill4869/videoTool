# 힉스필드 프리셋 보이스를 CRM 으로 들여온다.
#
# 서버가 힉스필드 API 를 직접 부르지 않는다 — 생성 키를 서버에 두지 않는다는 원칙 그대로다.
# 목록은 에이전트가 MCP(list_voices)로 받아서 여기에 적어 두고, 이 스크립트는 DB 에만 넣는다.
# 새 보이스가 생기면 목록을 다시 받아 이 파일을 갱신하고 다시 돌린다.
#
#   mix run priv/repo/sync_voices.exs

alias VideoTool.Repo
alias VideoTool.Presets.Voice

# {슬러그, 표시이름, 성별, 힉스필드 voice_id, 미리듣기}
voices = [
  {"arthur", "Arthur — 중년 남성, 차분한 다큐", "male", "30fc8796-ceb6-4a66-b3a7-4a145ef7f346",
   "https://d1xarpci4ikg0w.cloudfront.net/audio_voice_preset/preview/080fcbab-8be3-4d60-8156-3c3040421e0f.mp3"},
  {"holden", "Holden — 남성", "male", "3c9d6053-6334-592c-8997-4e325286af3f",
   "https://d1xarpci4ikg0w.cloudfront.net/audio_voice/3c9d6053-6334-592c-8997-4e325286af3f/preview-bddba899f043d6a8.mp3"},
  {"grady", "Grady — 남성", "male", "e2a2d2e6-9ed2-59cd-82af-feaa27f8a678",
   "https://d1xarpci4ikg0w.cloudfront.net/audio_voice/e2a2d2e6-9ed2-59cd-82af-feaa27f8a678/preview-c07e730034d0926d.mp3"},
  {"emmett", "Emmett — 남성", "male", "3c7d32be-0182-5c5e-aa6a-663409bfbb26",
   "https://d1xarpci4ikg0w.cloudfront.net/audio_voice/3c7d32be-0182-5c5e-aa6a-663409bfbb26/preview-eb4f23d8867ce233.mp3"},
  {"miles", "Miles — 남성", "male", "e18664a7-ee4f-5273-acf8-533eb24cd366",
   "https://d1xarpci4ikg0w.cloudfront.net/audio_voice/e18664a7-ee4f-5273-acf8-533eb24cd366/preview-0ae20b7a11f4bcc2.mp3"},
  {"barrett", "Barrett — 남성, 낮은 톤", "male", "d603a8cd-3fe1-55e0-9245-617a2589131e",
   "https://d1xarpci4ikg0w.cloudfront.net/audio_voice/d603a8cd-3fe1-55e0-9245-617a2589131e/preview-00167e6e5fdfbf02.mp3"},
  {"knox", "Knox — 남성", "male", "195e386a-cb61-5c1b-a53b-0e2f0669c408",
   "https://d1xarpci4ikg0w.cloudfront.net/audio_voice/195e386a-cb61-5c1b-a53b-0e2f0669c408/preview-cb24afb3a797d372.mp3"},
  {"marcus", "Marcus — 남성", "male", "6f98d3dd-324f-4845-8c28-c1d1647a06cd",
   "https://cdn.higgsfield.ai/audio_voice/cd7a989c-89ba-43c8-bc02-44a8c429825f.wav"},
  {"john", "John — 남성", "male", "6b528d43-c056-4a2f-9d82-1591a7ba13b0",
   "https://cdn.higgsfield.ai/audio_voice/fda261dc-1245-4bba-b47b-4debd425b31a.mp3"},
  {"celine", "Celine — 여성", "female", "57ccb351-84d7-54ba-afd4-26b566ca6023",
   "https://d1xarpci4ikg0w.cloudfront.net/audio_voice/57ccb351-84d7-54ba-afd4-26b566ca6023/preview-b8a818f93ce2e187.mp3"},
  {"helena", "Helena — 여성", "female", "3c2b83c0-2e0a-5ae8-998a-a5fe71b7eccd",
   "https://d1xarpci4ikg0w.cloudfront.net/audio_voice/3c2b83c0-2e0a-5ae8-998a-a5fe71b7eccd/preview-23723fb8dfc918c6.mp3"},
  {"maeve", "Maeve — 여성", "female", "64cf4f1a-61c8-5938-9aea-83d12b2e1d13",
   "https://d1xarpci4ikg0w.cloudfront.net/audio_voice/64cf4f1a-61c8-5938-9aea-83d12b2e1d13/preview-beb7ec12bc6be2ca.mp3"},
  {"opal", "Opal — 여성", "female", "66f35c82-2088-55eb-a0aa-7bf715dc03b7",
   "https://d1xarpci4ikg0w.cloudfront.net/audio_voice/66f35c82-2088-55eb-a0aa-7bf715dc03b7/preview-bc614761886f9553.mp3"},
  {"livia", "Livia — 여성", "female", "984ddbed-83d3-5388-84ce-02fe6c24befa",
   "https://d1xarpci4ikg0w.cloudfront.net/audio_voice/984ddbed-83d3-5388-84ce-02fe6c24befa/preview-33230197ddec20fe.mp3"},
  {"naomi", "Naomi — 여성", "female", "caeba733-3c17-43db-863e-69c7025512cd",
   "https://cdn.higgsfield.ai/audio_voice/bfe496ad-1296-441e-9ba6-02cfe4761eb3.wav"},
  {"emily", "Emily — 여성", "female", "6b3e3642-f7b7-4cb8-9688-51e233c4b92f",
   "https://cdn.higgsfield.ai/audio_voice/6cf1cf4b-8fd5-4ef2-abb7-10e43b2aa9be.mp3"}
]

# 실측 초당 글자수. 한 번이라도 재본 보이스는 그 값을 그대로 둔다 —
# 여기 기본값으로 덮어쓰면 실측이 사라진다.
default_cps = 8.2

Enum.each(voices, fn {slug, name, gender, voice_id, preview} ->
  existing = Repo.get_by(Voice, slug: slug)

  attrs = %{
    provider: "higgsfield",
    variant: "seed_audio",
    voice_id: voice_id,
    display_name: name,
    slug: slug,
    gender: gender,
    lang: "ko",
    preview_url: preview,
    speech_rate: 0.0,
    chars_per_sec: (existing && existing.sample_count > 0 && existing.chars_per_sec) || default_cps
  }

  case (existing || %Voice{}) |> Voice.changeset(attrs) |> Repo.insert_or_update() do
    {:ok, v} -> IO.puts("  #{v.slug}  #{v.display_name}")
    {:error, cs} -> IO.puts("  #{slug} 실패: #{inspect(cs.errors)}")
  end
end)

IO.puts("\n보이스 #{Repo.aggregate(Voice, :count)}개")
IO.puts("낭독 속도는 전부 0(보통)으로 넣었다. 길이가 안 맞으면 속도가 아니라 대본을 고친다.")
