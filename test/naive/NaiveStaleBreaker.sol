// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @title [반례] 누군가 check() 를 불러야 내려가는 차단기
/// @notice 처음 떠올린 구조: paused 를 저장해 두고, 감시 봇(keeper)이 주기적으로 check() 를 불러
///         보고서가 오래됐으면 paused = true 로 바꾼다. 발행은 paused 만 본다.
///
/// @dev 오라클 노드가 멈출 정도의 장애라면 감시 봇도 같이 멈춰 있을 가능성이 높다(같은 서버, 같은 RPC).
///      그러면 아무도 check() 를 부르지 않고, paused 는 false 로 남고, 사흘 전 재고 기준으로 발행이 계속된다.
///      (test_Exploit_KeeperDownMeansNoTrip)
///      SEC 랩 02 의 "오라클이 침묵하면 통과" 와 같은 문제가 차단기 자체에서 다시 나왔다.
///      CircuitBreaker 는 상태를 저장하지 않고 발행할 때마다 그 자리에서 계산한다.
contract NaiveStaleBreaker {
    uint256 public constant MAX_STALENESS = 24 hours;

    uint256 public updatedAt;
    bool public paused;

    function onReserveUpdate() external {
        updatedAt = block.timestamp;
    }

    function check() external {
        if (block.timestamp - updatedAt > MAX_STALENESS) paused = true;
    }

    function mintAllowed() external view returns (bool) {
        return !paused;
    }
}
