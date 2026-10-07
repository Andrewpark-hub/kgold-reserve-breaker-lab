// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ITransferGate {
    function transfersPaused() external view returns (bool);
}

/// @title KGold — 금 담보 토큰 (1 KGOLD = 금 1그램)
/// @notice decimals = 3 이라 최소 단위 1 = 금 1밀리그램이다. 보유고 증명(ReserveOracle)도
///         밀리그램 단위로 보고하므로, totalSupply 와 보관 중량을 단위 변환 없이 바로 비교한다.
///
/// @dev K-Gold 글에서 "발행 상한을 하드코딩한다는 명제는 성립하지 않았다 — 담보 가치가
///      가격 오라클의 출력이기 때문" 이라고 썼다. 여기서는 토큰을 가치가 아니라 **중량** 으로
///      정의해서 그 문제를 피한다. 금값이 어떻게 움직여도 "1토큰 = 1그램" 은 변하지 않으므로
///      발행 한도(= 보관 중량)가 이미 발행된 물량 밑으로 내려가지 않는다.
///      (가치 기준 설계가 깨지는 반례: test/naive/NaiveValueCappedMinter.sol)
///
///      K-Gold 설계대로 **등록된 기업 사이에서만** 전송된다(B2B 정산용).
///      회로차단기가 전송 정지를 걸면 전송·발행이 모두 멈춘다. 소각은 막지 않는다 —
///      소각은 발행량을 줄여 "발행량 ≤ 보관 중량" 을 회복하는 방향이기 때문이다.
contract KGold {
    string public constant name = "K-Gold";
    string public constant symbol = "KGOLD";
    uint8 public constant decimals = 3; // 1 단위 = 1 mg

    address public immutable admin; // 실제로는 운영 멀티시그
    address public minter; // MintController
    ITransferGate public breaker; // CircuitBreaker

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isRegistered;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Registered(address indexed company, bool registered);

    constructor(address _admin) {
        admin = _admin;
    }

    // ------------------------------------------------------------------
    // 관리
    // ------------------------------------------------------------------

    /// 배포 순서상 minter·breaker 는 토큰보다 늦게 생기므로, 한 번만 연결할 수 있게 했다.
    function wire(address _minter, ITransferGate _breaker) external {
        require(msg.sender == admin, "NOT_ADMIN");
        require(minter == address(0), "WIRED");
        minter = _minter;
        breaker = _breaker;
    }

    function setRegistered(address company, bool registered) external {
        require(msg.sender == admin, "NOT_ADMIN");
        isRegistered[company] = registered;
        emit Registered(company, registered);
    }

    // ------------------------------------------------------------------
    // 발행 · 소각 (MintController 만)
    // ------------------------------------------------------------------

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "NOT_MINTER");
        require(isRegistered[to], "NOT_REGISTERED");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == minter, "NOT_MINTER");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ------------------------------------------------------------------
    // ERC-20
    // ------------------------------------------------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    /// SEC 랩 01 에서 배운 것: 검사는 진입점(transfer / transferFrom)이 아니라
    /// 잔고가 실제로 움직이는 공통 경로에 둔다.
    function _move(address from, address to, uint256 amount) internal {
        require(!breaker.transfersPaused(), "PAUSED");
        require(isRegistered[from] && isRegistered[to], "NOT_REGISTERED");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
