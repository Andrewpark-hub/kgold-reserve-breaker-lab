// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {KGold} from "../src/KGold.sol";
import {ReserveOracle} from "../src/ReserveOracle.sol";
import {CircuitBreaker} from "../src/CircuitBreaker.sol";
import {MintController} from "../src/MintController.sol";

/// 퍼저가 무작위 순서로 호출하는 행동들.
/// 노드 5개 중 node1~3 은 정직하고, node4·5 는 악의적이다(정족수 3 미만).
contract Handler is Test {
    KGold token;
    ReserveOracle oracle;
    CircuitBreaker breaker;
    MintController minter;
    address admin;
    address importer;
    uint256[5] keys;
    address[5] nodes;

    // 고스트 변수 — 컨트랙트 밖에서 "정답" 을 따로 기록해 둔다
    uint256 public lastHonestReserve;
    uint256 public mintsWhileStale;
    uint256 public fakeAccepted;
    uint256 public mintsSucceeded; // 발행이 실제로 일어났는지 (불변식이 빈 검사가 아닌지 확인용)
    uint256 public overMints; // 발행 직후 발행량 > 보관량이었던 횟수

    constructor(
        KGold _token,
        ReserveOracle _oracle,
        CircuitBreaker _breaker,
        MintController _minter,
        address _admin,
        address _importer,
        uint256[5] memory _keys,
        address[5] memory _nodes
    ) {
        (token, oracle, breaker, minter) = (_token, _oracle, _breaker, _minter);
        (admin, importer, keys, nodes) = (_admin, _importer, _keys, _nodes);
        lastHonestReserve = oracle.reserveMg();
    }

    function _signSorted(ReserveOracle.Report memory r, uint256[] memory idx) internal view returns (bytes[] memory) {
        for (uint256 i = 1; i < idx.length; i++) {
            uint256 cur = idx[i];
            uint256 j = i;
            while (j > 0 && nodes[idx[j - 1]] > nodes[cur]) {
                idx[j] = idx[j - 1];
                j--;
            }
            idx[j] = cur;
        }
        bytes[] memory sigs = new bytes[](idx.length);
        for (uint256 i = 0; i < idx.length; i++) {
            (uint8 v, bytes32 rr, bytes32 s) = vm.sign(keys[idx[i]], oracle.digest(r));
            sigs[i] = abi.encodePacked(rr, s, v);
        }
        return sigs;
    }

    /// 정직한 노드 3개가 실제 재고 변화(±10%)를 보고한다
    function honestReport(uint256 pctSeed) external {
        vm.warp(block.timestamp + 1 hours);
        uint256 pct = bound(pctSeed, 90, 110);
        uint256 newReserve = lastHonestReserve * pct / 100;

        ReserveOracle.Report memory r = ReserveOracle.Report({
            round: oracle.latestRound() + 1, reserveMg: newReserve, observedAt: uint64(block.timestamp)
        });
        uint256[] memory idx = new uint256[](3);
        (idx[0], idx[1], idx[2]) = (0, 1, 2);
        oracle.submit(r, _signSorted(r, idx));
        lastHonestReserve = newReserve;
    }

    /// 악의적 노드 2개가 거짓 재고를 올리려고 한다. 서명을 중복으로 넣는 것까지 시도한다.
    function maliciousReport(uint256 fakeSeed, bool duplicate) external {
        vm.warp(block.timestamp + 1 hours);
        uint256 fake = bound(fakeSeed, 0, 1e15);

        ReserveOracle.Report memory r = ReserveOracle.Report({
            round: oracle.latestRound() + 1, reserveMg: fake, observedAt: uint64(block.timestamp)
        });
        uint256[] memory idx = new uint256[](2);
        (idx[0], idx[1]) = (3, 4);
        bytes[] memory two = _signSorted(r, idx);

        bytes[] memory sigs = new bytes[](3);
        (sigs[0], sigs[1], sigs[2]) = duplicate ? (two[0], two[0], two[1]) : (two[0], two[1], two[1]);

        try oracle.submit(r, sigs) {
            fakeAccepted++;
        } catch {}
    }

    function mint(uint256 amount) external {
        amount = bound(amount, 1, 500_000_000); // 한 번에 최대 500kg — 한도(약 1,000kg)에 실제로 닿아야 한다
        bool stale = breaker.isStale();
        vm.prank(admin);
        try minter.mint(importer, amount) {
            mintsSucceeded++;
            if (stale) mintsWhileStale++;
            if (token.totalSupply() > oracle.reserveMg()) overMints++;
        } catch {}
    }

    function redeem(uint256 amount) external {
        uint256 bal = token.balanceOf(importer);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(importer);
        minter.redeem(amount);
    }

    /// 운영자가 재고 감소를 점검하고 고점을 리셋한다
    function review() external {
        vm.prank(admin);
        breaker.acknowledgeReserve();
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 12 hours));
    }
}

/// K-Gold 설계의 핵심 주장 — "악의적 노드 수가 정족수 미만인 한 발행량 ≤ 증명된 보유량이 깨지지 않는다"
contract InvariantTest is Base {
    Handler handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(token, oracle, breaker, minter, admin, importer, nodeKeys, nodes);
        targetContract(address(handler));
    }

    /// 발행량 ≤ 보관량. 정직한 보고로 재고가 실제로 줄어 깨질 수는 있지만, 그때는 반드시 전송이 멈춰 있어야 한다.
    function invariant_SupplyWithinReserveOrPaused() public view {
        assertTrue(token.totalSupply() <= oracle.reserveMg() || breaker.transfersPaused());
    }

    /// 온체인 재고는 항상 정직한 노드들이 마지막으로 보고한 값이다.
    function invariant_ReserveOnlyFromHonestQuorum() public view {
        assertEq(oracle.reserveMg(), handler.lastHonestReserve());
        assertEq(handler.fakeAccepted(), 0);
    }

    /// 발행 직후 발행량이 보관량을 넘은 적이 한 번도 없다.
    function invariant_NoMintAboveReserve() public view {
        assertEq(handler.overMints(), 0);
    }

    /// 증명이 만료된 상태에서는 한 번도 발행되지 않았다.
    function invariant_NoMintWhileStale() public view {
        assertEq(handler.mintsWhileStale(), 0);
    }

    /// 퍼저가 실제로 발행까지 해 봤는지 실행이 끝날 때 출력한다
    function afterInvariant() public view {
        console.log("mints succeeded:", handler.mintsSucceeded());
    }
}
