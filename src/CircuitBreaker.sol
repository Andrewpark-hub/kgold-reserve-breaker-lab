// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IOracle {
    function reserveMg() external view returns (uint256);
    function updatedAt() external view returns (uint64);
}

interface ISupply {
    function totalSupply() external view returns (uint256);
}

/// @title CircuitBreaker — 이상이 감지되면 발행·전송을 멈춘다
/// @notice K-Gold 설계에서 정한 감지 조건 4개를 이렇게 옮겼다.
///         | 감지 조건          | 막는 것          |
///         | 증명 만료          | 신규 발행        |
///         | 재고 급감 (고점 대비) | 발행 + 전체 전송 |
///         | 담보 부족 (발행량 > 보관량) | 발행 + 전체 전송 |
///         | 서명 정족수 미달    | (보고서가 안 올라오므로 결국 "증명 만료" 로 잡힌다) |
///         여기에 운영자가 직접 거는 수동 정지를 더했다.
///
/// @dev 처음에는 paused 라는 bool 하나를 두고, 누군가 check() 를 호출해 이상을 발견하면
///      paused = true 로 바꾸는 구조였다. 그런데 이러면 **아무도 check() 를 부르지 않으면
///      차단기가 안 내려간다.** 오라클 노드가 멈추는 상황이면 그걸 감시하는 봇도 같이 멈춰 있을
///      가능성이 높다. (반례: test/naive/NaiveStaleBreaker.sol)
///      그래서 수동 정지를 뺀 나머지 조건은 저장하지 않고, 발행·전송이 일어날 때마다 **그 자리에서
///      계산하는 view** 로 바꿨다. SEC 랩 02 에서 배운 "모르면 멈춘다(fail-closed)" 와 같은 생각이다.
///
///      재고 급감은 "직전 보고서 대비" 로 비교하면 조금씩 여러 번 빼는 방식으로 피해갈 수 있다.
///      (반례: test/naive/NaiveDropBreaker.sol) 그래서 **마지막 점검 이후의 최고점** 대비로 비교한다.
///      고점은 오라클이 보고서를 받을 때마다 갱신하고, 운영자가 점검을 마치면 현재 값으로 리셋한다.
contract CircuitBreaker {
    uint256 public constant MAX_STALENESS = 24 hours; // 금고 실사 주기
    uint256 public constant DROP_LIMIT_BPS = 500; // 고점 대비 5% 이상 줄면 정지

    IOracle public immutable oracle;
    ISupply public immutable token;
    address public immutable guardian; // 실제로는 운영 멀티시그

    uint256 public highWaterMg; // 마지막 점검 이후 재고 최고점
    bool public manualPause;

    event ManualPause(bool paused);
    event Reviewed(uint256 newHighWaterMg);

    constructor(IOracle _oracle, ISupply _token, address _guardian) {
        oracle = _oracle;
        token = _token;
        guardian = _guardian;
    }

    // ------------------------------------------------------------------
    // 오라클 → 차단기 (재고가 바뀌는 유일한 경로)
    // ------------------------------------------------------------------

    function onReserveUpdate(uint256 reserveMg) external {
        require(msg.sender == address(oracle), "NOT_ORACLE");
        if (reserveMg > highWaterMg) highWaterMg = reserveMg;
    }

    // ------------------------------------------------------------------
    // 감지 조건 (전부 view — 누가 호출해 주지 않아도 항상 최신 상태)
    // ------------------------------------------------------------------

    function isStale() public view returns (bool) {
        return block.timestamp - oracle.updatedAt() > MAX_STALENESS;
    }

    function reserveDropped() public view returns (bool) {
        return oracle.reserveMg() * 10_000 < highWaterMg * (10_000 - DROP_LIMIT_BPS);
    }

    function undercollateralized() public view returns (bool) {
        return token.totalSupply() > oracle.reserveMg();
    }

    /// 전송까지 막는 조건 — 금이 실제로 사라졌을 수 있는 경우
    function transfersPaused() public view returns (bool) {
        return manualPause || reserveDropped() || undercollateralized();
    }

    /// 발행을 막는 조건 — 위의 것 + 재고를 확인할 수 없는 경우
    function mintAllowed() external view returns (bool) {
        return !transfersPaused() && !isStale();
    }

    // ------------------------------------------------------------------
    // 운영자
    // ------------------------------------------------------------------

    function setManualPause(bool paused) external {
        require(msg.sender == guardian, "NOT_GUARDIAN");
        manualPause = paused;
        emit ManualPause(paused);
    }

    /// 재고 감소를 점검하고 정상(예: 고객 상환으로 금이 실제로 나감)이라고 판단했을 때,
    /// 고점을 현재 값으로 내려 정지를 푼다. 발행량이 보관량보다 많으면 리셋해도 풀리지 않는다.
    function acknowledgeReserve() external {
        require(msg.sender == guardian, "NOT_GUARDIAN");
        highWaterMg = oracle.reserveMg();
        emit Reviewed(highWaterMg);
    }
}
