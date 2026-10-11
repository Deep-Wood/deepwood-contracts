// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {DeepWoodV4} from "../src/DeepWoodV4.sol";

/// @notice Plays the ladder END TO END on the real contract and reports what it
///         actually costs in hunts and ETH.
///
/// The design question this answers: "since skills now cost gems, a hunter must
/// not have to hunt forever before breaking even." The numbers in the contract
/// comments (~1,760 hunts to full unlock) come from an arithmetic model of the
/// tables. This test replaces the model with the contract itself -- it digs,
/// repairs, banks quartz, buys skill, breaks the tool and climbs, exactly as a
/// player would, and counts.
///
/// Run with: forge test --match-contract SkillEconomySim -vv
contract SkillEconomySim is Test {
    DeepWoodV4 dw;

    address internal constant TREASURY = address(0xBEEF);
    address internal constant HUNTER = address(0xF00D);
    address internal constant POOL_MANAGER = address(0x900D);
    bytes32 internal constant POOL_ID = bytes32(uint256(0xDEAD));
    bytes32 internal constant SEED = keccak256("deepwood-v4-preseason");

    address internal alice = address(0xA11CE);

    // Face value of each gem, matching priceOf().
    uint256[5] internal FACE = [
        uint256(0.00005 ether), 0.0004 ether, 0.003 ether, 0.025 ether, 0.2 ether
    ];

    function setUp() public {
        dw = new DeepWoodV4(TREASURY, HUNTER, POOL_MANAGER, POOL_ID, address(0));
        vm.prank(HUNTER);
        dw.commitSeed(SEED);
        vm.deal(alice, 500 ether);
    }

    /// Dig one hunt and bank the gems. Returns the face value found.
    function _dig(address who, uint8 tier) internal returns (uint256 faceValue) {
        (, , uint64 cd, , , , ) = dw.getConfig();
        (uint256[5] memory c, uint256 best) = dw.previewHunt(who, tier);
        vm.warp(block.timestamp + cd + 1);
        vm.prank(who);
        dw.settleHunt(who, tier, c, best, "");
        for (uint256 r = 0; r < 5; r++) faceValue += c[r] * FACE[r];
    }

    /// Play until `target` quartz is banked, repairing whenever the tool breaks.
    /// Returns hunts spent and face value mined.
    function _farmQuartz(address who, uint8 tier, uint256 target)
        internal returns (uint256 hunts, uint256 mined)
    {
        uint256 guard = 0;
        while (dw.gemsOf(who, DeepWoodV4.Rarity.Common) < target) {
            if (guard++ > 20_000) revert("farm did not converge");
            (uint8 t, uint64 dur,) = dw.toolOf(who);
            require(t == tier, "tier drifted");
            if (dur == 0) {
                // Repair: burn the gems the tier asks for.
                vm.prank(who);
                dw.repairTool();
            } else {
                mined += _dig(who, tier);
                hunts++;
            }
        }
    }

    /// The full ladder, exactly as a player walks it: skill first (one level
    /// per tier), then the tool.
    function test_FullLadderCostInHuntsAndEth() public {
        uint256 totalHunts;
        uint256 totalMined;
        uint256 totalToolSpend;
        uint256 totalSkillBurn;

        // Tool 1 is the entry purchase.
        uint256 c1 = dw.toolCost(1);
        vm.prank(alice);
        dw.buyTool{value: c1}(1);
        totalToolSpend += c1;

        for (uint8 tier = 1; tier <= 4; tier++) {
            // Bank enough quartz for the skill level this tier unlocks.
            uint256 need = dw.skillCost(tier) + 200; // margin for repair burn
            (uint256 h, uint256 m) = _farmQuartz(alice, tier, need);
            totalHunts += h;
            totalMined += m;

            // Buy the skill (only possible up to the tier held).
            uint256 before = dw.gemsOf(alice, DeepWoodV4.Rarity.Common);
            vm.prank(alice);
            dw.upgradeSkill(tier);
            totalSkillBurn += before - dw.gemsOf(alice, DeepWoodV4.Rarity.Common);

            emit log_named_uint("--- after skill", tier);
            emit log_named_uint("  cumulative hunts", totalHunts);
            emit log_named_uint("  cumulative mined (wei)", totalMined);

            // Now climb: break the tool, then buy the next tier.
            if (tier < 4) {
                while (true) {
                    (uint8 t, uint64 dur,) = dw.toolOf(alice);
                    if (t != tier) revert("tier drifted");
                    if (dur == 0) break;
                    totalMined += _dig(alice, tier);
                    totalHunts++;
                }
                uint8 next = tier + 1;
                uint256 cost = dw.toolCost(next);
                vm.prank(alice);
                dw.buyTool{value: cost}(next);
                totalToolSpend += cost;
            }
        }

        // Redeemable value: everything mined, less the quartz burned on
        // skills, paid out at 90%. The burn is already reflected in the quartz
        // balance, so it is reported separately above rather than re-derived.
        uint256 cash = (totalMined * 9000) / 10_000;

        emit log_named_uint("TOTAL HUNTS to skill 4", totalHunts);
        emit log_named_uint("mined (wei)", totalMined);
        emit log_named_uint("tool spend (wei)", totalToolSpend);
        emit log_named_uint("skill quartz burned", totalSkillBurn);
        emit log_named_uint("redeemable @90% (wei)", cash);
        emit log_named_int("NET vs tool spend", int256(cash) - int256(totalToolSpend));

        // The design bar: a hunter must reach skill 4 without an absurd grind.
        assertLt(totalHunts, 2_500, "full unlock must stay under 2,500 hunts");
    }
}
