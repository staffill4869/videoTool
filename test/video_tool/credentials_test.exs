defmodule VideoTool.CredentialsTest do
  # 리눅스 저장 경로(AES-GCM)만 본다. 윈도우 DPAPI 경로는 powershell 이 있어야 하고
  # 사용자 계정에 묶이므로 CI 에서 재현할 수 없다.
  use ExUnit.Case, async: false

  alias VideoTool.Credentials

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    old = Application.get_env(:video_tool, :credentials_dir)
    Application.put_env(:video_tool, :credentials_dir, dir)
    System.delete_env("VIDEOCRM_CRED_KEY")
    on_exit(fn -> Application.put_env(:video_tool, :credentials_dir, old) end)
    :ok
  end

  @tag :skip_on_windows
  test "넣은 것을 그대로 돌려준다", %{tmp_dir: dir} do
    if match?({:win32, _}, :os.type()) do
      # 윈도우에서는 DPAPI 경로를 타므로 이 검사는 의미가 없다.
      :ok
    else
      ref = "videoTool/youtube/yt-main"
      secret = ~s({"refresh_token":"1//abc","scope":"youtube.upload"})

      assert {:ok, ^ref} = Credentials.put(ref, secret)
      assert Credentials.exists?(ref)
      assert {:ok, ^secret} = Credentials.get(ref)

      # 평문이 디스크에 그대로 남으면 안 된다 — 암호화하는 이유가 그것이다.
      [file] = Path.wildcard(Path.join(dir, "*.dat"))
      raw = File.read!(file)
      refute raw =~ "refresh_token"
      refute raw =~ "1//abc"

      # 같은 값을 다시 넣어도 암호문은 달라야 한다 (IV 가 매번 새로 나온다).
      before = raw
      assert {:ok, ^ref} = Credentials.put(ref, secret)
      refute File.read!(file) == before

      assert :ok = Credentials.delete(ref)
      refute Credentials.exists?(ref)
      assert {:error, :not_found} = Credentials.get(ref)
    end
  end

  test "키가 바뀌면 열리지 않는다 — 조용히 빈 값을 주면 안 된다", %{tmp_dir: dir} do
    unless match?({:win32, _}, :os.type()) do
      ref = "videoTool/youtube/yt-cat"
      assert {:ok, _} = Credentials.put(ref, "비밀")

      # 키를 갈아끼운다 (서버를 옮기며 .key 를 안 가져온 상황)
      File.write!(Path.join(dir, ".key"), Base.encode64(:crypto.strong_rand_bytes(32)))

      assert {:error, msg} = Credentials.get(ref)
      assert msg =~ "다시 연결"
    end
  end
end
