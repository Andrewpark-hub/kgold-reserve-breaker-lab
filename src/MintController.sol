// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface IKGold {
    function totalSupply() external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

interface IReserve {
    function reserveMg() external view returns (uint256);
}

interface IBreaker {
    function mintAllowed() external view returns (bool);
}

/// @title MintController — 발행량 ≤ 증명된 보관 중량
/// @notice 수탁기관에 금이 입고되면 발행 담당자(issuer)가 그만큼 발행한다.
///         발행 직전에 두 가지를 확인한다.
///         1. 회로차단기가 발행을 허용하는가 (증명 만료·재고 급감·담보 부족·수동 정지가 아닌가)
///         2. 발행 후 총량이 오라클이 증명한 보관 중량을 넘지 않는가
///
/// @dev 2번의 비교는 **그램 대 그램** 이다. 금값은 어디에도 등장하지 않는다.
///      K-Gold 글에서 고민했던 "발행 상한 자체가 가격 오라클에 의존한다" 는 문제를, 토큰을 중량으로
///      정의하는 것으로 피했다. 대신 가격 변동은 이 토큰을 담보로 쓰는 쪽(무역 에스크로)의 담보 비율에서
///      다뤄야 한다 — 이건 아직 구현하지 않았다.
///
///      상환(redeem)은 차단기가 걸려 있어도 막지 않는다. 소각은 발행량을 줄이는 방향이라
///      불변식을 깨지 않는다. (실제 금 인출은 오프체인 절차라 여기선 소각만 한다)
contract MintController {
    IKGold public immutable token;
    IReserve public immutable oracle;
    IBreaker public immutable breaker;
    address public immutable issuer; // 실제로는 운영 멀티시그

    event Minted(address indexed to, uint256 amountMg);
    event Redeemed(address indexed from, uint256 amountMg);

    constructor(IKGold _token, IReserve _oracle, IBreaker _breaker, address _issuer) {
        token = _token;
        oracle = _oracle;
        breaker = _breaker;
        issuer = _issuer;
    }

    function mint(address to, uint256 amountMg) external {
        require(msg.sender == issuer, "NOT_ISSUER");
        require(breaker.mintAllowed(), "BREAKER");
        require(token.totalSupply() + amountMg <= oracle.reserveMg(), "EXCEEDS_RESERVE");
        token.mint(to, amountMg);
        emit Minted(to, amountMg);
    }

    function redeem(uint256 amountMg) external {
        token.burn(msg.sender, amountMg);
        emit Redeemed(msg.sender, amountMg);
    }
}
