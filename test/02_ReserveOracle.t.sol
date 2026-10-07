// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Base} from "./Base.t.sol";
import {ReserveOracle, IReserveListener} from "../src/ReserveOracle.sol";
import {NaiveReserveOracle} from "./naive/NaiveReserveOracle.sol";

contract ReserveOracleTest is Base {
    // ------------------------------------------------------------------
    // [반례] 서명 개수만 세는 오라클
    // ------------------------------------------------------------------

    function _naiveSign(NaiveReserveOracle o, uint256 reserveMg, uint64 at, uint256 key)
        internal
        pure
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, o.digest(reserveMg, at));
        return abi.encodePacked(r, s, v);
    }

    /// node5 혼자 재고를 10배로 부풀린 보고서에 서명하고, 같은 서명을 세 번 넣는다.
    function test_Exploit_OneNodeCountedThreeTimes() public {
        NaiveReserveOracle naive = new NaiveReserveOracle(nodes);
        bytes memory sig = _naiveSign(naive, 10_000 * KG, uint64(block.timestamp), nodeKeys[4]);

        bytes[] memory sigs = new bytes[](3);
        (sigs[0], sigs[1], sigs[2]) = (sig, sig, sig);
        naive.submit(10_000 * KG, uint64(block.timestamp), sigs);

        assertEq(naive.reserveMg(), 10_000 * KG, "one node alone set the reserve to 10x");
    }

    /// 1,000kg 일 때 3명이 서명한 보고서를 받아 둔다. 나중에 재고가 600kg 으로 줄어든 뒤
    /// 아무나 그 옛 보고서를 다시 제출하면 재고가 1,000kg 으로 되살아난다.
    function test_Exploit_OldReportReplayed() public {
        NaiveReserveOracle naive = new NaiveReserveOracle(nodes);
        uint64 t0 = uint64(block.timestamp);

        bytes[] memory oldSigs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            oldSigs[i] = _naiveSign(naive, 1000 * KG, t0, nodeKeys[i]);
        }
        naive.submit(1000 * KG, t0, oldSigs);

        vm.warp(block.timestamp + 7 days);
        bytes[] memory newSigs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            newSigs[i] = _naiveSign(naive, 600 * KG, uint64(block.timestamp), nodeKeys[i]);
        }
        naive.submit(600 * KG, uint64(block.timestamp), newSigs);
        assertEq(naive.reserveMg(), 600 * KG, "reserve really dropped");

        naive.submit(1000 * KG, t0, oldSigs); // 일주일 전 보고서 재제출

        assertEq(naive.reserveMg(), 1000 * KG, "a week-old report brought 400kg back");
    }

    // ------------------------------------------------------------------
    // 고친 오라클
    // ------------------------------------------------------------------

    function test_Fix_DuplicateSignatureRejected() public {
        vm.warp(block.timestamp + 1 hours);
        ReserveOracle.Report memory r = _nextReport(10_000 * KG);
        bytes memory sig = _sign(oracle, r, nodeKeys[4]);

        bytes[] memory sigs = new bytes[](3);
        (sigs[0], sigs[1], sigs[2]) = (sig, sig, sig);

        vm.expectRevert("UNSORTED_OR_DUPLICATE");
        oracle.submit(r, sigs);
    }

    /// 공격 시나리오 — 만료 증명 재사용
    function test_Fix_OldReportReplayRejected() public {
        // setUp 에서 1,000kg 보고서(round 1)가 들어가 있다. 같은 내용을 round 1 로 다시 만든다.
        ReserveOracle.Report memory old =
            ReserveOracle.Report({round: 1, reserveMg: 1000 * KG, observedAt: uint64(block.timestamp)});
        bytes[] memory oldSigs = _signSorted(oracle, old, _all());

        vm.warp(block.timestamp + 1 hours);
        _report(600 * KG, _all()); // round 2: 재고 감소

        vm.expectRevert("BAD_ROUND");
        oracle.submit(old, oldSigs);
        assertEq(oracle.reserveMg(), 600 * KG, "reserve stays at the latest report");
    }

    /// 서명은 받아 뒀다가 두 시간 뒤에 제출 — 내용이 이미 낡았다
    function test_Fix_ReportSignedLongAgoRejected() public {
        vm.warp(block.timestamp + 1 hours);
        ReserveOracle.Report memory r = _nextReport(1000 * KG);
        bytes[] memory sigs = _signSorted(oracle, r, _all());

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert("REPORT_TOO_OLD");
        oracle.submit(r, sigs);
    }

    /// 공격 시나리오 — 서명 재전송. 같은 노드들이 다른 배포본(테스트넷 오라클 등)에 해 준 서명은
    /// 도메인(컨트랙트 주소)이 달라서 여기서 복원하면 엉뚱한 주소가 나온다.
    function test_Fix_SignatureForOtherDeploymentRejected() public {
        ReserveOracle other = new ReserveOracle(admin, nodes);

        vm.warp(block.timestamp + 1 hours);
        ReserveOracle.Report memory r = _nextReport(10_000 * KG);
        bytes[] memory sigsForOther = _signSorted(other, r, _all());

        vm.expectRevert(); // 복원된 주소가 노드가 아니거나 정렬이 깨진다
        oracle.submit(r, sigsForOther);
    }

    /// (r, s) 가 유효하면 (r, n - s) 도 유효한 서명이다. 같은 서명의 "다른 모양" 을 막는다.
    function test_Fix_MalleableSignatureRejected() public {
        vm.warp(block.timestamp + 1 hours);
        ReserveOracle.Report memory r = _nextReport(1000 * KG);
        bytes[] memory sigs = _signSorted(oracle, r, _pick(0, 1, 2));

        bytes memory sig = sigs[0];
        bytes32 rr;
        bytes32 s;
        uint8 v;
        assembly {
            rr := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        sigs[0] = abi.encodePacked(rr, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27));

        vm.expectRevert("SIG_MALLEABLE");
        oracle.submit(r, sigs);
    }

    /// 공격 시나리오 — 검증 노드 조작. 노드 2개가 짜고 재고를 10배로 올려도 정족수(3)에 못 미친다.
    function test_Attack_TwoMaliciousNodesCannotFakeReserve() public {
        vm.warp(block.timestamp + 1 hours);
        ReserveOracle.Report memory fake = _nextReport(10_000 * KG);
        bytes[] memory sigs = _signSorted(oracle, fake, _pick(3, 4));

        vm.expectRevert("QUORUM");
        oracle.submit(fake, sigs);
        assertEq(oracle.reserveMg(), 1000 * KG, "reserve unchanged");
    }

    /// 한계: 3개가 짜면 막을 수 없다. 이건 버그가 아니라 m-of-n 의 신뢰 가정 그 자체다.
    /// 거짓 재고 10,000kg 이 인정되고, 실제로는 없는 금 9,000kg 어치가 발행된다.
    function test_Limit_ThreeColludingNodesWin() public {
        vm.warp(block.timestamp + 1 hours);
        _report(10_000 * KG, _pick(2, 3, 4));

        vm.prank(admin);
        minter.mint(importer, 10_000 * KG);

        assertEq(token.totalSupply(), 10_000 * KG, "9,000kg of tokens backed by nothing");
        assertFalse(breaker.transfersPaused(), "and the breaker sees nothing wrong");
    }

    function test_Oracle_ListenerWiredOnce() public {
        vm.prank(admin);
        vm.expectRevert("WIRED");
        oracle.setListener(IReserveListener(address(0xdead)));
    }
}
