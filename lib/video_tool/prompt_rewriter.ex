defmodule VideoTool.PromptRewriter do
  @moduledoc """
  "이렇게 바꿔줘" 라고 말하면 프롬프트를 고쳐 온다.

  서버에 깔린 `claude` CLI 를 부른다. 무인 루프가 쓰는 그 토큰을 그대로 쓴다.

  **바로 저장하지 않는다.** 고친 결과를 편집칸에 올려놓기만 하고, 사람이 읽어 보고
  직접 저장한다. 프롬프트 한 줄이 영상 수십 편을 좌우하는데, 말 한마디로 덮어쓰면
  무엇이 언제 왜 바뀌었는지 아무도 모르게 된다.
  """

  require Logger

  # 프롬프트는 길다(4천자 넘는다). 모델이 다 읽고 다시 쓸 시간을 준다.
  @timeout_ms 180_000

  @doc """
  `body` 를 `instruction` 대로 고쳐 돌려준다.

  `{:ok, 새_본문}` 또는 `{:error, 사람이 읽을 이유}`.
  """
  def rewrite(body, instruction, opts \\ [])

  def rewrite(body, instruction, _opts)
      when not is_binary(body) or not is_binary(instruction),
      do: {:error, "본문과 지시가 모두 필요합니다"}

  def rewrite(body, instruction, opts) do
    instruction = String.trim(instruction)

    cond do
      instruction == "" ->
        {:error, "무엇을 바꿀지 적어주세요"}

      String.trim(body) == "" ->
        {:error, "고칠 본문이 비어 있습니다"}

      true ->
        do_rewrite(body, instruction, Keyword.get(opts, :stage, ""))
    end
  end

  defp do_rewrite(body, instruction, stage) do
    # 지시와 본문을 **파일로** 건넨다. 인자로 넘기면 길이 제한과 따옴표에서 깨진다.
    input = build_input(body, instruction, stage)
    path = Path.join(System.tmp_dir!(), "vcrm_rewrite_#{System.unique_integer([:positive])}.txt")

    try do
      File.write!(path, input)

      case run_claude(path) do
        {:ok, out} -> extract(out, body)
        {:error, r} -> {:error, r}
      end
    after
      File.rm(path)
    end
  end

  defp build_input(body, instruction, stage) do
    """
    아래는 영상 제작 파이프라인이 쓰는 프롬프트다#{if stage != "", do: " (#{stage} 단계)", else: ""}.
    이것을 요청대로 고쳐서 **고친 전문만** 내놓아라.

    지켜야 할 것
    - 설명·인사·머리말을 붙이지 마라. 고친 프롬프트 본문만 낸다
    - 코드펜스(```)로 감싸지 마라
    - 요청한 곳만 고친다. 나머지 문장·구조·말투는 그대로 둔다
    - `{{var.이름}}` 같은 자리표시자는 **절대 지우거나 이름을 바꾸지 마라**
    - 번호 매긴 단계([1]~[8] 같은)가 있으면 번호와 순서를 유지한다
    - 한국어 프롬프트면 한국어로, 영어면 영어로 유지한다

    ===== 요청 =====
    #{instruction}

    ===== 지금 프롬프트 =====
    #{body}
    ===== 끝 =====
    """
  end

  defp run_claude(path) do
    env = [{"CLAUDE_CODE_OAUTH_TOKEN", token()}] |> Enum.reject(fn {_, v} -> is_nil(v) end)

    task =
      Task.async(fn ->
        System.cmd("bash", ["-c", "claude --print < #{path}"],
          stderr_to_stdout: true,
          env: env
        )
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} ->
        {:ok, out}

      {:ok, {out, code}} ->
        Logger.error("[prompt_rewriter] claude exit #{code}: #{String.slice(out, 0, 300)}")
        {:error, claude_reason(out, code)}

      nil ->
        {:error, "시간이 너무 걸려서 멈췄습니다 (3분). 요청을 더 좁혀서 다시 해보세요"}
    end
  rescue
    e in ErlangError -> {:error, "claude 를 실행할 수 없습니다: #{inspect(e.original)}"}
  end

  # 화면에 exit code 만 띄우면 무엇을 해야 할지 모른다. 흔한 두 가지는 풀어서 알려준다.
  defp claude_reason(out, code) do
    cond do
      out =~ "Not logged in" or out =~ "/login" ->
        "Claude 토큰이 없거나 만료됐습니다. 설정 화면의 'Claude 에이전트 토큰' 을 갱신하세요"

      out =~ "session limit" or out =~ "rate limit" ->
        "Claude 사용 한도에 걸렸습니다. 잠시 뒤 다시 해보세요"

      true ->
        "고치지 못했습니다 (exit #{code}): #{out |> String.trim() |> String.slice(0, 200)}"
    end
  end

  defp token do
    VideoTool.Settings.get(:claude_token) || System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
  end

  # 모델이 코드펜스를 씌우거나 한두 줄 덧붙이는 일이 있다. 벗겨내고,
  # 결과가 터무니없이 짧으면(=본문 대신 사과문을 보냈다) 거절한다 —
  # 그대로 편집칸에 올리면 사람이 모르고 저장한다.
  defp extract(out, original) do
    text =
      out
      |> String.trim()
      |> strip_fence()
      |> String.trim()

    min_len = max(div(String.length(original), 3), 80)

    cond do
      text == "" -> {:error, "빈 답이 왔습니다. 다시 해보세요"}
      String.length(text) < min_len -> {:error, "고친 결과가 너무 짧습니다:\n\n#{String.slice(text, 0, 300)}"}
      text == String.trim(original) -> {:error, "바뀐 게 없습니다. 요청을 더 구체적으로 적어보세요"}
      true -> {:ok, text}
    end
  end

  defp strip_fence(text) do
    case Regex.run(~r/\A```[a-zA-Z]*\n(.*)\n```\z/s, text) do
      [_, inner] -> inner
      _ -> text
    end
  end
end
