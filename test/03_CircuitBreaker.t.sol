// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Base} from "./Base.t.sol";
import {NaiveStaleBreaker} from "./naive/NaiveStaleBreaker.sol";
import {NaiveDropBreaker} from "./naive/NaiveDropBreaker.sol";

contract CircuitBreakerTest is Base {
    // ------------------------------------------------------------------
    // 증명 만료
    // ------------------------------------------------------------------

    /// [반례] 감시 봇이 check() 를 불러야 차단기가 내려가는 구조.
    /// 오라클과 봇이 같이 멈춘 사흘 동안 아무도 check() 를 부르지 않는다.
    function test_Exploit_KeeperDownMeansNoTrip() public {
        NaiveStaleBreaker naive = new NaiveStaleBreaker();
        naive.onReserveUpdate();

        vm.warp(block.timestamp + 3 days); // 노드도, 봇도 멈췄다

        assertTrue(naive.mintAllowed(), "minting still allowed on a 3-day-old reserve");

        // 봇이 살아 있었다면 걸렸을 것이다
        naive.check();
        assertFalse(naive.mintAllowed(), "only trips once someone calls check()");
    }

    /// 고친 차단기는 아무도 호출하지 않아도, 발행하는 순간 그 자리에서 만료를 계산한다.
    function test_Fix_StaleReserveBlocksMintWithoutAnyCall() public {
        vm.prank(admin);
        minter.mint(importer, 10 * KG);

        vm.warp(block.timestamp + 3 days);

        vm.prank(admin);
        vm.expectRevert("BREAKER");
        minter.mint(importer, 10 * KG);

        // 증명 만료는 "재고를 모른다" 일 뿐 금이 사라졌다는 뜻은 아니라서, 기업 간 전송은 그대로 둔다
        vm.prank(importer);
        token.transfer(exporter, 1 * KG);
        assertEq(token.balanceOf(exporter), 1 * KG, "transfers continue while stale");

        // 새 보고서가 올라오면 다시 발행할 수 있다
        _report(1000 * KG, _all());
        vm.prank(admin);
        minter.mint(importer, 10 * KG);
    }

    /// 공격 시나리오 — 기한 경계. 정확히 24시간째는 허용, 1초 뒤는 차단.
    function test_Boundary_StalenessAtExactly24Hours() public {
        uint256 t0 = block.timestamp;

        vm.warp(t0 + 24 hours);
        assertTrue(breaker.mintAllowed(), "exactly 24h: still fresh");

        vm.warp(t0 + 24 hours + 1);
        assertFalse(breaker.mintAllowed(), "24h + 1s: stale");
    }

    // ------------------------------------------------------------------
    // 재고 급감
    // ------------------------------------------------------------------

    /// [반례] 직전 대비 5% 기준. 4% 씩 다섯 번 줄이면 한 번도 안 걸리고 18% 가 사라진다.
    function test_Exploit_SlowDrainNeverTrips() public {
        NaiveDropBreaker naive = new NaiveDropBreaker(1000 * KG);

        uint256 reserve = 1000 * KG;
        for (uint256 i = 0; i < 5; i++) {
            reserve = reserve * 96 / 100;
            naive.onReserveUpdate(reserve);
        }

        assertFalse(naive.tripped(), "never tripped");
        assertLt(reserve, 820 * KG, "yet more than 18% of the gold is gone");
    }

    /// 고친 차단기는 고점(1,000kg) 대비로 본다. 같은 4% 감소가 두 번째에서 걸린다 (누적 7.84%).
    function test_Fix_SlowDrainTripsAgainstHighWater() public {
        vm.prank(admin);
        minter.mint(importer, 100 * KG);

        vm.warp(block.timestamp + 1 hours);
        _report(960 * KG, _all()); // -4%
        assertFalse(breaker.transfersPaused(), "first 4% drop: under the limit");

        vm.warp(block.timestamp + 1 hours);
        _report(921_600_000, _all()); // 또 -4% → 고점 대비 -7.84%
        assertTrue(breaker.reserveDropped(), "cumulative drop detected");

        vm.prank(importer);
        vm.expectRevert("PAUSED");
        token.transfer(exporter, 1 * KG);

        // 운영자가 점검 후 정상(예: 상환으로 실제 출고)이라고 확인하면 고점을 내리고 재개한다
        vm.prank(admin);
        breaker.acknowledgeReserve();
        assertFalse(breaker.transfersPaused(), "resumes after review");
    }

    /// 재고가 늘면 고점도 따라 올라간다. 2,000kg 까지 늘었다가 1,000kg 으로 반토막 나면,
    /// 처음 값(1,000kg)과 같아도 걸려야 한다.
    function test_Fix_HighWaterFollowsDeposits() public {
        vm.warp(block.timestamp + 1 hours);
        _report(2000 * KG, _all());
        assertEq(breaker.highWaterMg(), 2000 * KG);

        vm.warp(block.timestamp + 1 hours);
        _report(1000 * KG, _all());
        assertTrue(breaker.transfersPaused(), "50% drop from the high-water mark");
    }

    // ------------------------------------------------------------------
    // 담보 부족
    // ------------------------------------------------------------------

    /// 900kg 발행 후 재고가 800kg 으로 보고되면 발행량 > 보관량. 운영자 리셋만으로는 안 풀린다.
    /// 100kg 이 상환돼 발행량이 보관량 이하로 돌아와야 풀린다.
    function test_Fix_UndercollateralizedNeedsRedemptionNotJustReview() public {
        vm.prank(admin);
        minter.mint(importer, 900 * KG);

        vm.warp(block.timestamp + 1 hours);
        _report(800 * KG, _all());
        assertTrue(breaker.undercollateralized(), "supply 900kg > reserve 800kg");

        vm.prank(admin);
        breaker.acknowledgeReserve();
        assertTrue(breaker.transfersPaused(), "review alone cannot clear undercollateralization");

        vm.prank(importer);
        minter.redeem(100 * KG);
        assertFalse(breaker.transfersPaused(), "clears once supply is back within reserve");
    }

    // ------------------------------------------------------------------
    // 수동 정지
    // ------------------------------------------------------------------

    function test_ManualPause_OnlyGuardian() public {
        vm.prank(importer);
        vm.expectRevert("NOT_GUARDIAN");
        breaker.setManualPause(true);

        vm.prank(admin);
        breaker.setManualPause(true);
        assertFalse(breaker.mintAllowed());

        vm.prank(admin);
        breaker.setManualPause(false);
        assertTrue(breaker.mintAllowed());
    }
}
