defmodule VideoCRM.JSONTerm do
  @moduledoc """
  jsonb 컬럼에 임의의 JSON 값(주로 배열)을 그대로 넣고 뺀다.

  Ecto 의 `{:array, _}` 는 Postgres 배열 컬럼으로 매핑되므로 jsonb 에 넣을 수 없고,
  `:map` 은 최상위가 맵일 때만 받는다. `[[0.0, 13.4], ...]` 같은 값이 필요해서 통과용 타입을 둔다.
  """
  use Ecto.Type

  def type, do: :map

  def cast(value), do: {:ok, value}
  def load(value), do: {:ok, value}
  def dump(value), do: {:ok, value}

  def embed_as(_format), do: :self
  def equal?(a, b), do: a == b
end