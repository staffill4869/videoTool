defmodule VideoTool.FlowCharactersTest do
  use ExUnit.Case, async: true

  # `VideoTool.Series` 는 컨텍스트, 스키마는 `VideoTool.Series.Recipe` 다.
  # 컨텍스트를 Repo.get 에 넘기면 Protocol.UndefinedError 로 **생성 작업이 통째로 죽는다.**
  # 겉으로는 "생성을 눌렀습니다" 가 돌아와서 원인을 두 시간 동안 엉뚱한 데서 찾았다 (2026-10-01).
  test "시리즈 스키마 모듈이 Ecto 스키마다" do
    Code.ensure_loaded!(VideoTool.Series.Recipe)
    Code.ensure_loaded!(VideoTool.Series)

    assert function_exported?(VideoTool.Series.Recipe, :__schema__, 1)
    refute function_exported?(VideoTool.Series, :__schema__, 1)
    assert :flow_characters in VideoTool.Series.Recipe.__schema__(:fields)
  end
end
