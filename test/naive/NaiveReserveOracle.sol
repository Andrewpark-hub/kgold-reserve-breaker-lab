// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @title [반례] 서명 개수만 세는 보유고 오라클
/// @notice "등록된 노드의 서명이 3개 이상이면 인정" 을 가장 단순하게 옮겼다.
///         21회차에서 배운 대로 서명에서 서명자를 복원(ecrecover)하고, 노드인지 확인한다.
///
/// @dev 두 가지가 빠져 있다.
///      1. 서명자 중복을 안 본다 — 노드 하나가 같은 서명을 세 번 넣으면 3개로 센다.
///         (test_Exploit_OneNodeCountedThreeTimes)
///      2. 보고서 순서를 안 본다 — 재고가 줄어든 뒤, 예전에 3명이 서명했던 "많았던" 보고서를 아무나 다시
///         제출할 수 있다. 서명은 여전히 진짜라서 통과한다. (test_Exploit_OldReportReplayed)
///      도메인도 없어서 다른 배포본(테스트넷 등)에 낸 서명도 그대로 쓸 수 있다.
contract NaiveReserveOracle {
    uint256 public constant THRESHOLD = 3;

    mapping(address => bool) public isNode;
    uint256 public reserveMg;

    constructor(address[5] memory nodes) {
        for (uint256 i = 0; i < 5; i++) {
            isNode[nodes[i]] = true;
        }
    }

    function digest(uint256 _reserveMg, uint64 observedAt) public pure returns (bytes32) {
        return keccak256(abi.encode(_reserveMg, observedAt));
    }

    function submit(uint256 _reserveMg, uint64 observedAt, bytes[] calldata sigs) external {
        bytes32 d = digest(_reserveMg, observedAt);
        uint256 count;
        for (uint256 i = 0; i < sigs.length; i++) {
            bytes32 r = bytes32(sigs[i][0:32]);
            bytes32 s = bytes32(sigs[i][32:64]);
            uint8 v = uint8(sigs[i][64]);
            if (isNode[ecrecover(d, v, r, s)]) count++;
        }
        require(count >= THRESHOLD, "QUORUM");
        reserveMg = _reserveMg;
    }
}
