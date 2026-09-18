# 화장품 광고 프롬프트 (영어, 실사)

리뷰(2026-09-18, 67번 만화+실사 제품 편): "느낌은 괜찮은데 화장품이라 실제 사람이나 제품 실사로".
→ 화장품은 **전부 실사**. 만화·픽셀·의인화·3D 캐릭터 금지. 67번에서 좋았던 구성(모델 컷 사이에
제품 패키지샷·제형 매크로를 끼우는 것)은 그대로 두고 모델만 실사로 바꿨다.

| 파일 | 넣는 곳 |
|---|---|
| `standing.txt` | 프로젝트 `variables.standing_en` (+ `prompt_lang: en`) — `{{character}}` 로 들어간다 |
| `clean.txt` · `info.txt` · `video.txt` | `set_prompt_override(stage, body)` |

장면 `shot_prompt` 는 `[MODEL]` 또는 `[PRODUCT]` 로 시작한다. 프롬프트가 이 표시로 찍는 법을 가른다.

60초(8장면, 장면당 대사 약 38~45자 — 목소리마다 실측)
1. [MODEL] 피부 고민 2. [PRODUCT] 패키지샷 3. [MODEL] 덜기 4. [PRODUCT] 제형 매크로
5. [MODEL] 바르기 6. [MODEL] 겹쳐 바르기·메이크업 전 7. [MODEL] 결과 8. [MODEL] 제품 들고 인사 + 질문

30초(4장면): 1. [MODEL] 고민 2. [PRODUCT] 패키지샷 3. [MODEL] 바르기 4. [MODEL] 제품 들고 인사

- 실제 제품 사진이 생기면 `standing.txt` 의 PRODUCT 줄을 그 제품 묘사로 바꾸고, 라벨 규칙도 맞춘다
- 자막은 프롬프트가 아니라 합성 설정이다 (리뷰: 자막이 너무 작다 — 할일에 있음)
