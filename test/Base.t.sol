// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {KGold, ITransferGate} from "../src/KGold.sol";
import {ReserveOracle, IReserveListener} from "../src/ReserveOracle.sol";
import {CircuitBreaker, IOracle, ISupply} from "../src/CircuitBreaker.sol";
import {MintController, IKGold, IReserve, IBreaker} from "../src/MintController.sol";

/// 전체 시스템 배포 + 검증 노드 서명 헬퍼
abstract contract Base is Test {
    address admin = makeAddr("admin"); // 운영 멀티시그 역할 (토큰 관리 · 회로차단기 guardian · 발행 담당)
    address importer = makeAddr("importer"); // 수입사 A
    address exporter = makeAddr("exporter"); // 수출사 B

    // 검증 노드 5개의 개인키 (vm.sign 용)
    uint256[5] nodeKeys;
    address[5] nodes;

    KGold token;
    ReserveOracle oracle;
    CircuitBreaker breaker;
    MintController minter;

    uint256 constant KG = 1_000_000; // 1kg = 1,000,000 mg = 1,000 KGOLD

    function setUp() public virtual {
        vm.warp(1_790_000_000); // 2026-09 즈음, 0 근처 타임스탬프에서 생기는 언더플로 방지

        for (uint256 i = 0; i < 5; i++) {
            (nodes[i], nodeKeys[i]) = makeAddrAndKey(string.concat("node", vm.toString(i + 1)));
        }

        vm.startPrank(admin);
        token = new KGold(admin);
        oracle = new ReserveOracle(admin, nodes);
        breaker = new CircuitBreaker(IOracle(address(oracle)), ISupply(address(token)), admin);
        minter =
            new MintController(IKGold(address(token)), IReserve(address(oracle)), IBreaker(address(breaker)), admin);

        token.wire(address(minter), ITransferGate(address(breaker)));
        oracle.setListener(IReserveListener(address(breaker)));
        token.setRegistered(importer, true);
        token.setRegistered(exporter, true);
        vm.stopPrank();

        // 금고에 금 1,000kg 이 입고됐다는 첫 보고서
        _report(1000 * KG, _all());
    }

    // ------------------------------------------------------------------
    // 서명 헬퍼
    // ------------------------------------------------------------------

    function _all() internal pure returns (uint256[] memory idx) {
        idx = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            idx[i] = i;
        }
    }

    function _pick(uint256 a, uint256 b) internal pure returns (uint256[] memory idx) {
        idx = new uint256[](2);
        (idx[0], idx[1]) = (a, b);
    }

    function _pick(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory idx) {
        idx = new uint256[](3);
        (idx[0], idx[1], idx[2]) = (a, b, c);
    }

    function _sign(ReserveOracle o, ReserveOracle.Report memory r, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(key, o.digest(r));
        return abi.encodePacked(rr, s, v);
    }

    /// 고른 노드들의 서명을 주소 오름차순으로 정렬해서 돌려준다 (오라클이 정렬을 요구한다)
    function _signSorted(ReserveOracle o, ReserveOracle.Report memory r, uint256[] memory idx)
        internal
        view
        returns (bytes[] memory sigs)
    {
        // 단순 삽입 정렬 — 노드가 5개뿐이라 충분하다
        for (uint256 i = 1; i < idx.length; i++) {
            uint256 cur = idx[i];
            uint256 j = i;
            while (j > 0 && nodes[idx[j - 1]] > nodes[cur]) {
                idx[j] = idx[j - 1];
                j--;
            }
            idx[j] = cur;
        }
        sigs = new bytes[](idx.length);
        for (uint256 i = 0; i < idx.length; i++) {
            sigs[i] = _sign(o, r, nodeKeys[idx[i]]);
        }
    }

    function _nextReport(uint256 reserveMg) internal view returns (ReserveOracle.Report memory) {
        return ReserveOracle.Report({
            round: oracle.latestRound() + 1, reserveMg: reserveMg, observedAt: uint64(block.timestamp)
        });
    }

    /// 다음 라운드 보고서를 만들어 고른 노드들의 서명으로 제출한다
    function _report(uint256 reserveMg, uint256[] memory idx) internal {
        ReserveOracle.Report memory r = _nextReport(reserveMg);
        oracle.submit(r, _signSorted(oracle, r, idx));
    }
}
