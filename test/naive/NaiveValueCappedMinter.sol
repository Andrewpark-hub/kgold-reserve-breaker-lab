// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @title [반례] 가치 기준 발행 한도 — K-Gold 글에서 처음 세웠던 전제
/// @notice 처음 설계에서는 토큰 1개를 "금 1,000원어치" 로 두고, 발행 한도를
///         "금고 보관 중량 × 금 시세" 로 계산했다. 담보 가치만큼만 찍겠다는 생각이었다.
///
/// @dev 금값이 내리면 한도가 내려간다. 그런데 이미 발행돼 남의 지갑에 들어간 토큰은 줄일 방법이 없다.
///      한도가 발행량 밑으로 내려가는 순간 "발행량 ≤ 한도" 가 깨지고, 고칠 수단이 없다.
///      (test_Exploit_PriceDropPushesCapBelowSupply)
///      MintController 는 토큰을 중량(1토큰 = 1g)으로 정의해서 금값을 비교식에서 아예 뺐다.
contract NaiveValueCappedMinter {
    uint256 public constant TOKEN_VALUE_KRW = 1_000; // 1토큰 = 1,000원어치

    uint256 public vaultGrams;
    uint256 public goldPriceKrwPerGram; // 가격 오라클 값
    uint256 public totalSupply;

    constructor(uint256 _vaultGrams, uint256 _price) {
        vaultGrams = _vaultGrams;
        goldPriceKrwPerGram = _price;
    }

    function cap() public view returns (uint256) {
        return vaultGrams * goldPriceKrwPerGram / TOKEN_VALUE_KRW;
    }

    function mint(uint256 amount) external {
        require(totalSupply + amount <= cap(), "EXCEEDS_CAP");
        totalSupply += amount;
    }

    function setPrice(uint256 price) external {
        goldPriceKrwPerGram = price;
    }
}
