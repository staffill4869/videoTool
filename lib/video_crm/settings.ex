defmodule VideoCRM.Settings do
  @moduledoc """
  자격증명과 환경 상태.

  읽는 순서는 **자격증명 저장소 → 환경변수** 다. 화면에서 넣은 값이 `.env` 를 이긴다 —
  화면에서 고쳤는데 `.env` 값이 계속 이기면 왜 안 바뀌는지 알 방법이 없다.

  저장은 항상 DPAPI(`VideoCRM.Credentials`)로 한다. DB 에도 `.env` 에도 평문으로 두지 않는다.
  """

  alias VideoCRM.{Credentials, Flow, Ocr, Ffmpeg}

  # 이름 → {자격증명 키, 환경변수 이름, 화면 표시, 설명}
  @secrets [
    {:google_api_key, "settings/google_api_key", "GOOGLE_API_KEY", "유튜브 API 키",
     "조회수·좋아요·댓글 수집. 공개 영상은 이것만 있으면 되고 OAuth 는 필요 없다."},
    {:google_client_id, "settings/google_client_id", "GOOGLE_CLIENT_ID", "구글 OAuth 클라이언트 ID",
     "유튜브 업로드·자막·섬네일. 애플리케이션 유형은 '데스크톱 앱'."},
    {:google_client_secret, "settings/google_client_secret", "GOOGLE_CLIENT_SECRET",
     "구글 OAuth 클라이언트 시크릿", "위 클라이언트 ID 와 한 쌍."},
    {:higgsfield_api_key, "settings/higgsfield_api_key", "HIGGSFIELD_API_KEY", "힉스필드 API 키",
     "TTS 나레이션 (4주차)."}
  ]

  def secrets, do: @secrets

  def definition(name) do
    Enum.find(@secrets, fn {key, _, _, _, _} -> key == name end)
  end

  @doc "값을 읽는다. 자격증명 저장소가 먼저, 없으면 환경변수."
  def get(name) do
    case definition(name) do
      nil ->
        nil

      {_key, ref, env, _label, _help} ->
        case Credentials.get(ref) do
          {:ok, value} when value != "" -> value
          _ -> blank_to_nil(System.get_env(env))
        end
    end
  end

  def set(name, value) do
    case definition(name) do
      nil ->
        {:error, "모르는 설정: #{name}"}

      {_key, ref, _env, _label, _help} ->
        if blank?(value) do
          Credentials.delete(ref)
          {:ok, :cleared}
        else
          Credentials.put(ref, String.trim(value))
        end
    end
  end

  def set?(name), do: not is_nil(get(name))

  @doc "값을 그대로 보여주지 않는다. 앞뒤 몇 글자만 남긴다."
  def masked(name) do
    case get(name) do
      nil -> nil
      value when byte_size(value) <= 8 -> String.duplicate("•", String.length(value))
      value -> String.slice(value, 0, 4) <> String.duplicate("•", 8) <> String.slice(value, -4, 4)
    end
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @doc """
  이 PC 에서 무엇이 준비됐는지. 화면과 MCP 가 같은 값을 쓴다 —
  둘이 다르게 판단하면 "화면은 된다는데 왜 안 되냐" 가 된다.
  """
  def status do
    %{
      google_api_key: %{
        ready: set?(:google_api_key),
        label: "유튜브 API 키",
        enables: "조회수·좋아요·댓글 수집",
        hint: "GCP → YouTube Data API v3 사용 설정 → API 키"
      },
      google_oauth: %{
        ready: set?(:google_client_id) and set?(:google_client_secret),
        label: "구글 OAuth 클라이언트",
        enables: "유튜브 업로드·자막·섬네일",
        hint: "GCP → 사용자 인증 정보 → OAuth 클라이언트 ID → 데스크톱 앱"
      },
      higgsfield: %{
        ready: set?(:higgsfield_api_key),
        label: "힉스필드 API 키",
        enables: "TTS 나레이션 (4주차)",
        hint: "힉스필드 계정에서 발급"
      },
      ffmpeg: %{
        ready: Ffmpeg.available?(),
        label: "ffmpeg",
        enables: "프레임 추출 · 해시 · 합성",
        hint: "scoop install ffmpeg"
      },
      tesseract: %{
        ready: Ocr.available?(),
        label: "tesseract (한국어)",
        enables: "허용 수치 검증 · OCR 매핑 보강",
        hint: "scoop install tesseract + kor.traineddata"
      },
      flow_chrome: %{
        ready: match?({:ok, %{prompt_box: true}}, Flow.status()),
        label: "Flow 브라우저",
        enables: "Flow 자동 조종",
        hint: "launch-chrome.ps1 실행 후 구글 로그인"
      }
    }
  end
end