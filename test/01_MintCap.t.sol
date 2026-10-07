// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Base} from "./Base.t.sol";
import {NaiveValueCappedMinter} from "./naive/NaiveValueCappedMinter.sol";

contract MintCapTest is Base {
    /// 기준선: 증명된 보관 중량(1,000kg) 안에서는 정상 발행된다.
    function test_Mint_WithinReserve() public {
        vm.prank(admin);
        minter.mint(importer, 400 * KG);

        assertEq(token.balanceOf(importer), 400 * KG, "400kg minted");
        assertEq(token.totalSupply(), 400 * KG);
    }

    /// [반례] 가치 기준 한도. 금 1,000g, 시세 15만원/g 이면 한도는 15만 토큰(1토큰 = 1,000원).
    /// 한도까지 발행한 뒤 금값이 20% 내리면 한도가 12만으로 내려가는데, 이미 나간 15만 토큰은 그대로다.
    function test_Exploit_PriceDropPushesCapBelowSupply() public {
        NaiveValueCappedMinter naive = new NaiveValueCappedMinter(1_000, 150_000);
        naive.mint(150_000);
        assertEq(naive.totalSupply(), naive.cap(), "minted exactly up to the cap");

        naive.setPrice(120_000); // 금값 20% 하락

        assertEq(naive.cap(), 120_000, "cap fell with the price");
        assertGt(naive.totalSupply(), naive.cap(), "supply is now above the cap");
        // 한도를 다시 맞추려면 남의 지갑에 있는 3만 토큰을 없애야 하는데, 그런 함수는 없다(있어서도 안 된다).
    }

    /// 중량 기준에서는 비교식에 금값이 없다. 보관량을 1mg 이라도 넘으면 막힌다. (공격 시나리오 — 과잉 발행 시도)
    function test_Attack_OverMintReverts() public {
        vm.startPrank(admin);
        minter.mint(importer, 1000 * KG); // 보관량 전부

        vm.expectRevert("EXCEEDS_RESERVE");
        minter.mint(importer, 1); // 1mg 더
        vm.stopPrank();
    }

    function test_Mint_OnlyIssuer() public {
        vm.prank(importer);
        vm.expectRevert("NOT_ISSUER");
        minter.mint(importer, 1 * KG);
    }

    /// 등록되지 않은 주소로는 발행도 전송도 안 된다 (B2B 화이트리스트)
    function test_Mint_OnlyRegisteredCompanies() public {
        address stranger = makeAddr("stranger");

        vm.prank(admin);
        vm.expectRevert("NOT_REGISTERED");
        minter.mint(stranger, 1 * KG);

        vm.prank(admin);
        minter.mint(importer, 1 * KG);
        vm.prank(importer);
        vm.expectRevert("NOT_REGISTERED");
        token.transfer(stranger, 1);
    }

    /// 차단기가 걸려도 상환(소각)은 된다. 소각은 발행량을 줄여 불변식을 회복하는 방향이다.
    function test_Redeem_AllowedWhilePaused() public {
        vm.prank(admin);
        minter.mint(importer, 10 * KG);

        vm.prank(admin);
        breaker.setManualPause(true);

        vm.prank(importer);
        vm.expectRevert("PAUSED");
        token.transfer(exporter, 1 * KG);

        vm.prank(importer);
        minter.redeem(10 * KG);
        assertEq(token.totalSupply(), 0, "redeemed while paused");
    }
}
