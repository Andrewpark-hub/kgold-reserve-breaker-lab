// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IReserveListener {
    function onReserveUpdate(uint256 reserveMg) external;
}

/// @title ReserveOracle — 보유고 증명 (검증 노드 5개 중 3개 이상의 서명)
/// @notice 각 검증 노드는 수탁기관 금고의 재고를 독립적으로 확인하고, 같은 보고서
///         (round, reserveMg, observedAt) 에 EIP-712 서명을 한다. 서로 다른 노드 3개 이상의
///         서명이 모인 보고서만 온체인에 기록된다.
///
/// @dev 다중 서명 검증에서 막아야 했던 것들 (반례: test/naive/NaiveReserveOracle.sol)
///      1. 같은 서명 중복 집계 — 노드 하나가 자기 서명을 세 번 내면 "3명이 동의" 가 된다.
///         → 복원한 서명자 주소가 **엄격하게 증가** 해야 한다. 정렬을 강제하면 중복이 저절로 막힌다.
///      2. 과거 보고서 재제출 — 재고가 줄어든 뒤 예전의 "많았던" 보고서를 다시 내면 재고가 되살아난다.
///         → round 는 정확히 직전 + 1, observedAt 은 직전보다 나중이어야 한다.
///      3. 서명해 두고 늦게 제출 — 서명은 유효해도 내용이 이미 낡았을 수 있다.
///         → 제출 시점에 observedAt 이 MAX_REPORT_AGE 보다 오래됐으면 거부한다.
///      4. 다른 배포본의 서명 재사용 — 테스트넷용 서명을 메인넷 오라클에 내는 경우.
///         → EIP-712 도메인에 chainId 와 이 컨트랙트 주소가 들어간다.
///      5. 서명 가변성(malleability) — 같은 메시지에 대한 (r, s) 와 (r, n - s) 는 둘 다 유효하다.
///         → s 를 곡선 위수의 절반 이하로 제한한다(EIP-2).
contract ReserveOracle {
    uint256 public constant NODE_COUNT = 5;
    uint256 public constant THRESHOLD = 3;
    uint256 public constant MAX_REPORT_AGE = 1 hours;

    bytes32 public constant REPORT_TYPEHASH = keccak256("Report(uint64 round,uint256 reserveMg,uint64 observedAt)");
    // secp256k1 위수 n 의 절반
    uint256 private constant HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    struct Report {
        uint64 round;
        uint256 reserveMg; // 금고 보관 중량 (밀리그램)
        uint64 observedAt; // 노드들이 재고를 확인한 시각
    }

    bytes32 public immutable DOMAIN_SEPARATOR;
    address public immutable admin;
    IReserveListener public listener; // CircuitBreaker

    mapping(address => bool) public isNode;

    uint64 public latestRound;
    uint256 public reserveMg;
    uint64 public updatedAt; // 마지막으로 인정된 보고서의 observedAt

    event ReserveUpdated(uint64 indexed round, uint256 reserveMg, uint64 observedAt);

    constructor(address _admin, address[NODE_COUNT] memory nodes) {
        admin = _admin;
        for (uint256 i = 0; i < NODE_COUNT; i++) {
            require(nodes[i] != address(0) && !isNode[nodes[i]], "BAD_NODE");
            isNode[nodes[i]] = true;
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("K-Gold ReserveOracle"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function setListener(IReserveListener _listener) external {
        require(msg.sender == admin, "NOT_ADMIN");
        require(address(listener) == address(0), "WIRED");
        listener = _listener;
    }

    function digest(Report calldata r) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(REPORT_TYPEHASH, r.round, r.reserveMg, r.observedAt));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    /// 누구나 제출할 수 있다. 권한은 제출자가 아니라 서명에서 온다.
    /// @param signatures 서명자 주소 오름차순으로 정렬된 65바이트 서명들
    function submit(Report calldata r, bytes[] calldata signatures) external {
        require(r.round == latestRound + 1, "BAD_ROUND");
        require(r.observedAt > updatedAt, "NOT_NEWER");
        require(r.observedAt <= block.timestamp, "FUTURE");
        require(block.timestamp - r.observedAt <= MAX_REPORT_AGE, "REPORT_TOO_OLD");
        require(signatures.length >= THRESHOLD, "QUORUM");

        bytes32 d = digest(r);
        address prev = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = _recover(d, signatures[i]);
            require(signer > prev, "UNSORTED_OR_DUPLICATE");
            require(isNode[signer], "NOT_NODE");
            prev = signer;
        }

        latestRound = r.round;
        reserveMg = r.reserveMg;
        updatedAt = r.observedAt;
        emit ReserveUpdated(r.round, r.reserveMg, r.observedAt);

        // 재고가 바뀌는 경로는 여기 하나뿐이다. 회로차단기의 고점 기록도 여기서 갱신한다.
        listener.onReserveUpdate(r.reserveMg);
    }

    function _recover(bytes32 d, bytes calldata sig) internal pure returns (address signer) {
        require(sig.length == 65, "SIG_LENGTH");
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        require(uint256(s) <= HALF_N, "SIG_MALLEABLE");
        require(v == 27 || v == 28, "SIG_V");
        signer = ecrecover(d, v, r, s);
        require(signer != address(0), "SIG_INVALID");
    }
}
