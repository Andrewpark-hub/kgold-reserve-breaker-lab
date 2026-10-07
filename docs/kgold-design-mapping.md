# K-Gold 설계 → 컨트랙트 매핑

출처: K-Gold 설계(핀테크 아이디어 공모전)와 지난 LinkedIn 글 「금고에 금이 실제로 있다는 것을, 스마트 컨트랙트는 어떻게 믿을 수 있을까요?」

> 이 문서는 **내 설계 문서에 적었던 규칙**을 컨트랙트로 옮기면서 무엇을 만들었고 무엇을 남겼는지 정리한 것이다.
> 실제 수탁기관·검증 노드·금 시세와는 연동하지 않았다. 구현은 설계가 "맞다" 는 증명이 아니라,
> 설계 문장을 코드로 옮길 때 **어디서 깨지기 쉬운지** 를 보려고 만든 최소 예제다.

## 설계 구성 요소 전체

| 구성 요소 | 설계에서 정한 규칙 | 이 레포 |
|---|---|---|
| 금 담보 토큰 | 1토큰 = 금 1그램, 등록된 기업 간에만 전송 | ✅ `KGold.sol` |
| 발행 관리자 | 총 발행량 ≤ 증명된 보관 중량 | ✅ `MintController.sol` |
| 보유고 증명 | 검증 노드 n 개 중 m 개 이상 + 유효시간 내 서명 | ✅ `ReserveOracle.sol` (3-of-5, EIP-712) |
| 회로차단기 | 감지 조건 4개 중 하나라도 충족 시 정지 | ✅ `CircuitBreaker.sol` |
| 무역 에스크로 | 담보 잠금, 결재선 2-of-3 승인 시 정산, 기한 초과 시 환불 | ❌ 다음 과제 |
| 검증 노드 프로그램 | 각 노드가 금고 재고를 확인하고 서명 | ❌ 테스트에서 `vm.sign` 으로 대신함 |
| 대시보드 | 기업 재무 담당자용 화면 | ❌ 범위 밖 |
| MPC 지갑 · 계정 추상화 | 기업 내부 다중 서명 | ❌ 범위 밖 (에스크로 결재선에서 EIP-712 다중 승인으로 대신할 계획) |

## 회로차단기 감지 조건

| 감지 조건 | 설계에서 정한 조치 | 구현 | 테스트 |
|---|---|---|---|
| 증명 만료 | 신규 발행 중지 | `isStale()` — 24시간 | `test_Fix_StaleReserveBlocksMintWithoutAnyCall`, `test_Boundary_StalenessAtExactly24Hours` |
| 재고 급감 | 전체 전송 정지 후 수동 검토 | `reserveDropped()` — 고점 대비 5% | `test_Fix_SlowDrainTripsAgainstHighWater`, `test_Fix_HighWaterFollowsDeposits` |
| 담보 비율 미달 | 해당 계약 정산 보류 | ⚠️ 토큰 전체 기준(`undercollateralized()` — 발행량 > 보관량)으로만 구현. 계약별 담보 비율은 에스크로에서 | `test_Fix_UndercollateralizedNeedsRedemptionNotJustReview` |
| 서명 정족수 미달 | 증명 갱신 거부 | `QUORUM` revert → 보고서가 안 올라오므로 결국 증명 만료로 잡힌다 | `test_Attack_TwoMaliciousNodesCannotFakeReserve` |

## 공격 시나리오

| 시나리오 | 테스트 | 결과 |
|---|---|---|
| 과잉 발행 시도 | `test_Attack_OverMintReverts` | 1mg 초과도 `EXCEEDS_RESERVE` |
| 검증 노드 조작 (정족수 미만) | `test_Attack_TwoMaliciousNodesCannotFakeReserve` | `QUORUM` |
| 검증 노드 조작 (정족수 이상) | `test_Limit_ThreeColludingNodesWin` | ❗ 막을 수 없음 — 신뢰 가정의 한계 |
| 만료 증명 재사용 | `test_Fix_OldReportReplayRejected`, `test_Fix_ReportSignedLongAgoRejected` | `BAD_ROUND`, `REPORT_TOO_OLD` |
| 서명 재전송 (다른 배포본) | `test_Fix_SignatureForOtherDeploymentRejected` | EIP-712 도메인 불일치로 거부 |
| 서명 중복 · 가변성 | `test_Fix_DuplicateSignatureRejected`, `test_Fix_MalleableSignatureRejected` | `UNSORTED_OR_DUPLICATE`, `SIG_MALLEABLE` |
| 단독 결재 우회 | — | ❌ 에스크로 미구현 |
| 기한 경계 조건 | `test_Boundary_StalenessAtExactly24Hours` | 24시간째 허용, +1초 차단 (에스크로 기한은 미구현) |

## K-Gold 글에서 무너졌던 전제 3개 → 이번에 확인한 것

| 글에서 쓴 것 | 이번 구현에서 |
|---|---|
| "발행 상한을 하드코딩한다는 명제는 성립하지 않았다 — 담보 가치가 가격 오라클 출력이다" | 가치 기준이면 금값 하락 시 한도 < 발행량이 되고 되돌릴 수 없다(반례 01). **중량 기준**으로 바꿔 토큰에서 가격을 뺐다. 가격 위험은 에스크로로 이동 |
| "다수 노드의 교차 검증은 신뢰를 없앤 게 아니라 분산시킨 것" | 3개가 짜면 끝난다는 걸 `test_Limit_ThreeColludingNodesWin` 으로 남겼다 |
| "EVM 호환은 툴체인 호환이지 상호운용성이 아니다 — 브릿지가 가장 위험" | 이번 범위 밖. 단일 체인 안에서만 구현했다 |

## 남은 질문

- 고점 리셋(`acknowledgeReserve`)을 운영자 한 명이 아니라 결재선 다중 승인으로 바꾸면, 리셋 자체에도 지연·공개 문제가 생기지 않을까? (스테이블코인 동결 글의 대기 시간 문제와 같은 모양)
- 증명 만료 때 전송까지 막아야 하나? 막으면 정상 기업의 정산까지 멈추고, 안 막으면 금이 실제로 사라졌을 때 유통이 계속된다.
- 노드 3개 담합을 테스트 밖에서 줄이려면? 노드마다 다른 수탁기관 · 다른 감사인을 두는 운영 설계가 필요해 보이는데, 이건 코드로 강제할 수 없다.
- 24시간 만료와 5% 급감 기준은 근거 없이 정했다. 실제 금 수탁기관의 실사 주기와 재고 변동 폭을 찾아보고 다시 정해야 한다.
