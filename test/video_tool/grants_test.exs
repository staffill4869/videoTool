defmodule VideoTool.GrantsTest do
  @moduledoc """
  기업마당 공고 한 건을 우리 모양으로 바꾸는 부분.

  네트워크는 안 탄다 — API 응답 한 건을 그대로 넣고 변환만 본다.
  """
  use ExUnit.Case, async: true

  alias VideoTool.Grants

  @item %{
    "pblancId" => "PBLN_000000000112233",
    "pblancNm" => "  2026년 수출바우처 지원사업  ",
    "jrsdInsttNm" => "중소벤처기업부",
    "pldirSportRealmLclasCodeNm" => "수출",
    "trgetNm" => "중소기업",
    "reqstBeginEndDe" => "2026-09-16 ~ 2026-10-02",
    "bsnsSumryCn" => "<p>수출<b>바우처</b>를&nbsp;드립니다.</p><p><br></p>",
    "reqstMthPapersCn" => "<p>온라인 신청</p>",
    "hashtags" => "수출, 중소기업 , ,바우처",
    "pblancUrl" => "https://www.bizinfo.go.kr/x",
    "printFlpthNm" => "/cmm/fms/getImage.do?atchFileId=A1"
  }

  test "HTML 을 벗기고 빈 값은 nil 로 만든다" do
    g = Grants.from_api(@item)

    assert g.title == "2026년 수출바우처 지원사업"
    # 태그 제거 + &nbsp; 를 공백으로 + 공백 정리
    assert g.summary == "수출 바우처 를 드립니다."
    assert g.how_to_apply == "온라인 신청"
    assert g.hashtags == ["수출", "중소기업", "바우처"]
  end

  test "마감일은 기간 문자열의 뒷날짜다" do
    assert Grants.from_api(@item).ends_on == ~D[2026-10-02]
  end

  test "상시 접수는 마감일이 없다 — 날짜가 없다고 버리면 안 된다" do
    g = Grants.from_api(%{@item | "reqstBeginEndDe" => "예산 소진시까지"})

    assert g.ends_on == nil
    assert g.period == "예산 소진시까지"
  end

  test "첨부 공고문은 절대 주소로 만든다 — 금액·자격이 거기 있다" do
    assert Grants.from_api(@item).attachment ==
             "https://www.bizinfo.go.kr/cmm/fms/getImage.do?atchFileId=A1"

    assert Grants.from_api(%{@item | "printFlpthNm" => ""}).attachment == nil
  end

  test "id 나 제목이 없는 것은 버린다" do
    assert Grants.from_api(%{"pblancNm" => "제목만"}) == nil
    assert Grants.from_api(%{@item | "pblancId" => ""}) == nil
  end
end
