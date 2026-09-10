defmodule VideoCRM.Mapping do
  @moduledoc """
  Flow 결과물을 장면에 붙인다.

  파일명은 근거가 못 된다 — `Battleships_facing_across_sea.mp4` 의 실제 내용이 쿠릴 열도였다.
  생성 시각도 마찬가지다. 그래서 화면 내용으로 맞춘다.

  단계별 근거가 다르다.
    * CLEAN — 라벨이 없어 OCR 이 안 된다. 파일 순서를 쓰되 신뢰도를 낮게 잡는다
    * INFO  — 같은 그림에 라벨만 얹은 것이라 CLEAN 과 phash 가 가깝다. OCR 이 있으면 라벨로 보강
    * 클립  — 첫 프레임은 CLEAN 과, 마지막 프레임은 INFO 와 대조한다 (체인)
  """

  alias VideoCRM.{Assignment, Media, Ocr, Phash, Projects}

  @low_confidence 0.7
  # 1등과 2등 점수 차가 이보다 작으면 구분했다고 볼 수 없다.
  @ambiguity_epsilon 0.02

  @doc "kind 별로 배정한다. 반환값은 %{asset_id => {scene_id, confidence}}."
  def assign(project, "clean", assets), do: by_order(project, assets)
  def assign(project, "info", assets), do: by_similarity(project, assets, "clean", :phash)
  def assign(project, "clip", assets), do: by_chain(project, assets)

  def low_confidence?(confidence), do: confidence < @low_confidence

  # ── CLEAN — 순서 기반 ───────────────────────────────────────────

  defp by_order(project, assets) do
    scenes = Projects.scenes(project.id)

    assets
    |> Enum.sort_by(& &1.source_filename)
    |> Enum.zip(scenes)
    |> Map.new(fn {asset, scene} -> {asset.id, {scene.id, 0.5}} end)
  end

  # ── INFO — CLEAN 과의 phash 유사도 (+ OCR 라벨 보강) ────────────

  defp by_similarity(project, assets, reference_kind, hash_field) do
    scenes = Projects.scenes(project.id)
    reference = reference_by_scene(project, reference_kind)

    if map_size(reference) == 0 do
      # 기준이 될 CLEAN 이 아직 없다 — 순서로 떨어뜨린다
      by_order(project, assets)
    else
      ocr_texts = maybe_ocr(assets)

      matrix =
        Enum.map(scenes, fn scene ->
          Enum.map(assets, fn asset ->
            -score(scene, asset, reference, hash_field, ocr_texts)
          end)
        end)

      solve_into(matrix, scenes, assets, fn scene, asset ->
        score(scene, asset, reference, hash_field, ocr_texts)
      end)
    end
  end

  defp score(scene, asset, reference, hash_field, ocr_texts) do
    visual =
      case Map.get(reference, scene.id) do
        nil -> 0.5
        ref_hash -> Phash.similarity(ref_hash, Map.get(asset, hash_field) || "")
      end

    # OCR 이 아무것도 못 읽었으면 그건 "라벨이 틀렸다" 가 아니라 "모른다" 다.
    # 0 점으로 섞으면 시각 매칭이 완벽해도 신뢰도가 깎여 멀쩡한 배정이 빨갛게 뜬다.
    case Map.get(ocr_texts, asset.id) do
      nil -> visual
      text -> if Ocr.legible?(text), do: visual * 0.6 + label_match(scene, text) * 0.4, else: visual
    end
  end

  # expected_labels 가 화면에서 몇 개나 읽혔는가.
  defp label_match(%{expected_labels: []}, _text), do: 0.5

  defp label_match(%{expected_labels: labels}, text) do
    stripped = String.replace(text, ~r/\s/u, "")

    hits =
      Enum.count(labels, fn label ->
        String.contains?(stripped, String.replace(label, ~r/\s/u, ""))
      end)

    hits / length(labels)
  end

  # ── 클립 — 첫 프레임=CLEAN, 마지막 프레임=INFO 체인 ─────────────

  defp by_chain(project, assets) do
    scenes = Projects.scenes(project.id)
    cleans = reference_by_scene(project, "clean")
    infos = reference_by_scene(project, "info")

    matrix =
      Enum.map(scenes, fn scene ->
        Enum.map(assets, fn asset -> -chain_score(scene, asset, cleans, infos) end)
      end)

    solve_into(matrix, scenes, assets, fn scene, asset ->
      chain_score(scene, asset, cleans, infos)
    end)
  end

  defp chain_score(scene, asset, cleans, infos) do
    head = similarity_or(Map.get(cleans, scene.id), asset.phash, 0.5)
    tail = similarity_or(Map.get(infos, scene.id), asset.phash_last, 0.5)

    # 두 끝이 서로 다른 장면을 가리키면 신뢰할 수 없다. 평균이 아니라 낮은 쪽에 무게를 둔다.
    min(head, tail) * 0.7 + (head + tail) / 2 * 0.3
  end

  defp similarity_or(nil, _hash, fallback), do: fallback
  defp similarity_or(_ref, "", fallback), do: fallback
  defp similarity_or(ref, hash, _fallback), do: Phash.similarity(ref, hash)

  # ── 공통 ────────────────────────────────────────────────────────

  defp solve_into([], _scenes, _assets, _scorer), do: %{}

  defp solve_into(matrix, scenes, assets, scorer) do
    # 헝가리안은 열 ≥ 행을 요구한다. 자산이 모자라면 행/열을 뒤집는다.
    assignment =
      if length(assets) < length(scenes) do
        # 행/열을 뒤집는다: 행=자산, 열=장면
        assets
        |> Enum.map(fn asset -> Enum.map(scenes, fn scene -> -scorer.(scene, asset) end) end)
        |> Assignment.solve()
        |> Map.new(fn {row, col} -> {Enum.at(assets, row), Enum.at(scenes, col)} end)
      else
        # 행=장면, 열=자산
        matrix
        |> Assignment.solve()
        |> Map.new(fn {row, col} -> {Enum.at(assets, col), Enum.at(scenes, row)} end)
      end

    Map.new(assignment, fn {asset, scene} ->
      score = scorer.(scene, asset)
      {asset.id, {scene.id, Float.round(penalize(score, asset, scenes, scorer), 3)}}
    end)
  end

  # 2등 장면과 사실상 동점이면 배정이 맞았더라도 근거가 없다.
  # 동점일 때 헝가리안은 순서대로 배정하는데, 그건 파일 순서를 믿은 것과 같다 —
  # Flow 파일명이 내용과 무관하다는 게 이 단계의 전제이므로 그런 배정은 신뢰할 수 없다.
  # 높은 신뢰도로 내보내면 틀린 순서가 조용히 통과하므로 여기서 떨어뜨린다.
  defp penalize(score, asset, scenes, scorer) do
    case scenes |> Enum.map(&scorer.(&1, asset)) |> Enum.sort(:desc) do
      [best, second | _] when best - second < @ambiguity_epsilon -> min(score, 0.3)
      _ -> score
    end
  end

  defp reference_by_scene(project, kind) do
    project.id
    |> Media.list_assets(kind)
    |> Enum.filter(&(&1.scene_id && &1.phash != ""))
    |> Map.new(&{&1.scene_id, &1.phash})
  end

  # OCR 이 없으면 조용히 건너뛴다 — 시각 유사도만으로도 배정은 된다.
  # (단 허용 수치 검증은 OCR 없이 성립하지 않는다. Validation 참조.)
  defp maybe_ocr(assets) do
    if Ocr.available?() do
      Map.new(assets, fn asset ->
        case Ocr.text(asset.file_path) do
          {:ok, text} -> {asset.id, text}
          _ -> {asset.id, ""}
        end
      end)
    else
      %{}
    end
  end
end