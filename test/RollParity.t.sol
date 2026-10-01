// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeepWood} from "../src/DeepWood.sol";

/// @notice The contract and script/hunt-engine.mjs must agree EXACTLY.
///
/// The client renders hunts locally and only then asks the chain to settle them.
/// If the Solidity roll and the JS roll diverge by even one gem, every hunt a
/// player sees is rejected with ResultMismatch -- the game looks broken in a way
/// no unit test on either side would explain.
///
/// The vectors are GENERATED FROM THE JS ENGINE by script/gen-roll-vectors.mjs,
/// never read back out of the contract, so this is a genuine cross-implementation
/// check rather than the contract agreeing with itself.
///
/// Two shapes, because a roll depends on both the tool tier and the per-player
/// hunt index:
///   rows -- index 0 for every tier and every player. previewHunt needs no tool,
///           so all four tiers are covered with no settlement at all.
///   walk -- tier 1 across three successive indices, settling in between so the
///           hunt index genuinely advances.
contract RollParityTest is Test {
    struct Roll {
        address player;
        uint8 tier;
        uint64 index;
        uint256[5] counts;
        uint256 best;
    }

    DeepWood dw;
    bytes32 internal constant SEED = keccak256("deepwood-season-1-seed");

    Roll[] rows;
    Roll[] walk;

    function setUp() public {
        dw = new DeepWood(address(this), address(this));
        dw.commitSeason(bytes32(uint256(0xC0FFEE)));
        dw.commitSeed(SEED); // = keccak256("deepwood-season-1-seed")
        // Season 1 starts closed now, and these vectors settle hunts -- so arm
        // it the way an owner would. Without this every parity settlement
        // reverts SeasonNotOpen, which is the gate working, not a parity fault.
        dw.openSeason();

rows.push(Roll(address(uint160(919791448120245735144748008190597589268974010368)), 1, 0, [uint256(4), 0, 0, 0, 0], 50000000000000));
        rows.push(Roll(address(uint160(919791448120245735144748008190597589268974010368)), 2, 0, [uint256(4), 0, 0, 0, 0], 50000000000000));
        rows.push(Roll(address(uint160(919791448120245735144748008190597589268974010368)), 3, 0, [uint256(2), 1, 0, 1, 0], 25000000000000000));
        rows.push(Roll(address(uint160(919791448120245735144748008190597589268974010368)), 4, 0, [uint256(1), 2, 1, 0, 0], 3000000000000000));
        rows.push(Roll(address(uint160(1062543919097768023009010231535588908293806882816)), 1, 0, [uint256(5), 0, 0, 0, 0], 50000000000000));
        rows.push(Roll(address(uint160(1062543919097768023009010231535588908293806882816)), 2, 0, [uint256(3), 2, 0, 0, 0], 400000000000000));
        rows.push(Roll(address(uint160(1062543919097768023009010231535588908293806882816)), 3, 0, [uint256(2), 0, 2, 1, 0], 25000000000000000));
        rows.push(Roll(address(uint160(1062543919097768023009010231535588908293806882816)), 4, 0, [uint256(3), 0, 2, 0, 0], 3000000000000000));

walk.push(Roll(address(uint160(919791448120245735144748008190597589268974010368)), 1, 0, [uint256(4), 0, 0, 0, 0], 50000000000000));
        walk.push(Roll(address(uint160(919791448120245735144748008190597589268974010368)), 1, 1, [uint256(5), 0, 0, 0, 0], 50000000000000));
        walk.push(Roll(address(uint160(919791448120245735144748008190597589268974010368)), 1, 2, [uint256(3), 0, 0, 0, 0], 50000000000000));
        walk.push(Roll(address(uint160(1062543919097768023009010231535588908293806882816)), 1, 0, [uint256(5), 0, 0, 0, 0], 50000000000000));
        walk.push(Roll(address(uint160(1062543919097768023009010231535588908293806882816)), 1, 1, [uint256(4), 0, 0, 0, 0], 50000000000000));
        walk.push(Roll(address(uint160(1062543919097768023009010231535588908293806882816)), 1, 2, [uint256(3), 1, 0, 0, 0], 400000000000000));
    }

    function _check(uint256[5] memory got, uint256 gotBest, Roll memory v) internal pure {
        for (uint256 j = 0; j < 5; j++) {
            assertEq(got[j], v.counts[j], "gem count differs between engine and contract");
        }
        assertEq(gotBest, v.best, "best-single differs between engine and contract");
    }

    function test_AllTiersMatchTheEngine() public {
        assertEq(rows.length, 8, "two players x four tiers");
        for (uint256 r = 0; r < rows.length; r++) {
            (uint256[5] memory c, uint256 best) = dw.previewHunt(rows[r].player, rows[r].tier);
            _check(c, best, rows[r]);
        }
    }

    function test_HuntIndexAdvancesTheStreamLikeTheEngine() public {
        assertEq(walk.length, 6, "two players x three indices");
        (, , uint64 cd, , , , ) = dw.getConfig();
        for (uint256 w = 0; w < walk.length; w++) {
            Roll memory v = walk[w];
            if (v.index == 0) {
                vm.prank(v.player);
                dw.claimTool(1);
            }
            assertEq(dw.huntIndexOf(v.player), v.index, "index must line up before rolling");
            (uint256[5] memory c, uint256 best) = dw.previewHunt(v.player, v.tier);
            _check(c, best, v);
            vm.warp(block.timestamp + cd + 1);
            vm.prank(v.player);
            dw.settleHunt(v.player, v.tier, c, best, "");
        }
    }

    function test_RollDependsOnThePlayerNotJustTheSeed() public {
        (uint256[5] memory a,) = dw.previewHunt(address(uint160(919791448120245735144748008190597589268974010368)), 1);
        (uint256[5] memory b,) = dw.previewHunt(address(uint160(1062543919097768023009010231535588908293806882816)), 1);
        bool same = true;
        for (uint256 j = 0; j < 5; j++) {
            if (a[j] != b[j]) same = false;
        }
        assertFalse(same, "two players at the same index must not roll identically");
    }
}
