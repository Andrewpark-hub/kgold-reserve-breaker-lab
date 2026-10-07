// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @title [반례] 직전 보고서 대비로 재고 급감을 잡는 차단기
/// @notice "재고가 직전보다 5% 이상 줄면 정지" — 설계 문서의 "직전 증명 대비 보관 중량이 임계치 이상
///         감소" 를 그대로 옮겼다.
///
/// @dev 한 번에 5% 를 빼면 걸린다. 그런데 4% 씩 다섯 번 빼면 한 번도 안 걸리고 누적 18% 가 사라진다.
///      (test_Exploit_SlowDrainNeverTrips)
///      SEC 랩의 자정 경계 문제와 같은 모양이다 — 비교 기준을 매번 새로 잡으면 경계를 나눠서 넘을 수 있다.
///      CircuitBreaker 는 "마지막 점검 이후의 최고점" 대비로 비교한다.
contract NaiveDropBreaker {
    uint256 public constant DROP_LIMIT_BPS = 500;

    uint256 public lastReserve;
    bool public tripped;

    constructor(uint256 initialReserve) {
        lastReserve = initialReserve;
    }

    function onReserveUpdate(uint256 reserve) external {
        if (reserve * 10_000 < lastReserve * (10_000 - DROP_LIMIT_BPS)) tripped = true;
        lastReserve = reserve; // 기준이 매번 직전 값으로 내려간다
    }
}
