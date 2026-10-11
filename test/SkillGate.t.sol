// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {DeepWoodV4} from "../src/DeepWoodV4.sol";

/// @notice The tool/skill interlock and the rarity gate (SPEC section 2).
///
/// The design, in the user's words: "you can only upgrade your skill once per
/// tier and it's irrelevant until you upgrade your tool. So if a wood hunter
/// upgrades skill to 1, it doesn't give them amber until they upgrade to
/// bronze."
///
/// Formalised:
///   * skill N unlocks Rarity(N): 1=Amber 2=Sapphire 3=Ruby 4=Diamond
///   * upgradeSkill(N) requires holding tier >= N   (one level per tier)
///   * buyTool(N)      requires skillOf >= N-1      (skill before tool)
///   => a player holding tier T always sits at skill T-1 or T
///   * dropTable REDIRECTS every locked rarity's weight down to Quartz, so a
///     locked gem can never be rolled and an unskilled hunter is 100% Quartz
///
/// Together these mean a tier's top rarity is always unlocked by the time the
/// player holds that tier -- and every tool a player can hold is repairable,
/// because tier N's repair needs exactly the gems skill N-1 unlocks.
contract SkillGateTest is Test {
    DeepWoodV4 dw;

    address internal constant TREASURY = address(0xBEEF);
    address internal constant HUNTER = address(0xF00D);
    address internal constant POOL_MANAGER = address(0x900D);
    bytes32 internal constant POOL_ID = bytes32(uint256(0xDEAD));
    bytes32 internal constant SEED = keccak256("deepwood-v4-preseason");

    address internal alice = address(0xA11CE);

    function setUp() public {
        dw = new DeepWoodV4(TREASURY, HUNTER, POOL_MANAGER, POOL_ID, address(0));
        vm.prank(HUNTER);
        dw.commitSeed(SEED);
        vm.deal(alice, 100 ether);
    }

    // ---- the gate REDIRECTS, it does not zero ----------------------------

    /// A locked rarity's weight must move to Quartz, not vanish. This is what
    /// keeps every row a 10k distribution and guarantees an unskilled hunter
    /// still earns -- if the weight were zeroed, a tier-3 tool at skill 0
    /// would mine only 4,500/10,000 quartz and silently lose the remainder.
    function test_LockedWeightRedirectsToQuartz() public view {
        uint256[5] memory t1 = dw.dropTable(5, 0);
        assertEq(t1[0], 10_000, "unskilled gold is 100% quartz");

        uint256[5] memory t3 = dw.dropTable(3, 0);
        assertEq(t3[0], 10_000, "4500+3500+2000 all collapse into quartz");
        assertEq(t3[1], 0);
        assertEq(t3[2], 0);
    }

    /// Every row, at every tier/skill pair, is still a 10,000 distribution.
    function test_EveryRowSumsToTenThousand() public view {
        for (uint8 tier = 1; tier <= 5; tier++) {
            for (uint8 s = 0; s <= 4; s++) {
                uint256[5] memory t = dw.dropTable(tier, s);
                uint256 sum;
                for (uint256 r = 0; r < 5; r++) sum += t[r];
                assertEq(sum, 10_000, "row must be a 10k distribution");
            }
        }
    }

    /// The gate is monotonic: raising skill only ever ADDS rarities, shrinks
    /// quartz, and opens the rarity that level is named for -- provided the
    /// TIER can produce it at all. Wood's table is quartz-only, so no amount
    /// of skill opens Amber there; the level is inert, which is the point.
    function test_HigherSkillIsStrictlyMorePermissive() public view {
        for (uint8 tier = 1; tier <= 5; tier++) {
            for (uint8 s = 0; s < 4; s++) {
                uint256[5] memory lo = dw.dropTable(tier, s);
                uint256[5] memory hi = dw.dropTable(tier, s + 1);
                assertLe(hi[0], lo[0], "quartz must not grow with skill");

                // The tier's OWN ceiling decides whether the level can open
                // anything here. skill 4 on a Wood tool opens nothing.
                uint256[5] memory ceiling = dw.dropTable(tier, 4);
                if (ceiling[s + 1] > 0) {
                    assertGt(hi[s + 1], 0, "the level must open its named rarity");
                } else {
                    assertEq(hi[s + 1], 0, "tier cannot produce this rarity at all");
                }
            }
        }
    }

    /// A tier's own table is its ceiling -- skill can lower it but never raise
    /// it. Wood stays quartz-only even at skill 4.
    function test_SkillCannotRaiseATiersCeiling() public view {
        uint256[5] memory wood = dw.dropTable(1, 4);
        assertEq(wood[0], 10_000, "wood is quartz-only at any skill");
        assertEq(wood[1], 0, "wood can never produce amber");

        uint256[5] memory bronze = dw.dropTable(2, 4);
        assertEq(bronze[2], 0, "bronze can never produce sapphire");
    }

    // ---- the interlock ----------------------------------------------------

    /// One level per tier. A Wood hunter may buy skill 1 but not skill 2, and
    /// cannot skip straight to the top.
    function test_OneSkillLevelPerTier() public {
        _buyTier(alice, 1);
        _grantQuartz(alice, 6_000);

        vm.prank(alice);
        dw.upgradeSkill(1);
        assertEq(dw.skillOf(alice), 1);

        vm.prank(alice);
        vm.expectRevert(DeepWoodV4.TierLocked.selector);
        dw.upgradeSkill(2);

        vm.prank(alice);
        vm.expectRevert(DeepWoodV4.TierLocked.selector);
        dw.upgradeSkill(4);
    }

    /// You cannot buy a skill without holding a tool at all.
    function test_SkillRequiresATool() public {
        _grantQuartz(alice, 6_000);
        vm.prank(alice);
        vm.expectRevert(DeepWoodV4.ToolNotOwned.selector);
        dw.upgradeSkill(1);
    }

    /// Skill before tool: tier 2 needs skill 1, tier 3 needs skill 2, and so
    /// on. This makes the ladder literal rather than advisory.
    function test_ToolRequiresTheMatchingSkill() public {
        _buyTier(alice, 1);
        _grantQuartz(alice, 6_000);
        _breakTool(alice);

        uint256 cost = dw.toolCost(2);
        vm.prank(alice);
        vm.expectRevert(DeepWoodV4.TierLocked.selector);
        dw.buyTool{value: cost}(2);

        vm.prank(alice);
        dw.upgradeSkill(1);

        vm.prank(alice);
        dw.buyTool{value: cost}(2);
        (uint8 tier,,) = dw.toolOf(alice);
        assertEq(tier, 2, "the same purchase now goes through");
    }

    /// The first tool is the exception: tier 1 needs no skill, so a brand new
    /// player can always start.
    function test_FirstToolNeedsNoSkill() public {
        assertEq(dw.skillOf(alice), 0);
        _buyTier(alice, 1);
        (uint8 tier,,) = dw.toolOf(alice);
        assertEq(tier, 1, "a skill-0 player can still buy the entry tool");
    }

    // ---- the user's own example ------------------------------------------

    /// "if a wood hunter upgrades skill to 1, it doesn't give them amber until
    /// they upgrade to bronze" -- the level is INERT until the tool matches.
    function test_SkillIsInertUntilTheToolCatchesUp() public {
        _buyTier(alice, 1);
        _grantQuartz(alice, 6_000);
        vm.prank(alice);
        dw.upgradeSkill(1);

        // Skill 1 says Amber is unlocked...
        assertTrue(dw.rarityUnlocked(alice, DeepWoodV4.Rarity.Uncommon), "skill 1 unlocks amber");

        // ...but Wood's table is quartz-only, so nothing changes in practice.
        uint256[5] memory wood = dw.dropTable(1, dw.skillOf(alice));
        assertEq(wood[0], 10_000, "wood still mines 100% quartz");
        assertEq(wood[1], 0, "no amber at wood even with skill 1");

        // Bronze is where the permission becomes real.
        _breakTool(alice);
        uint256 cost = dw.toolCost(2);
        vm.prank(alice);
        dw.buyTool{value: cost}(2);
        uint256[5] memory bronze = dw.dropTable(2, dw.skillOf(alice));
        assertEq(bronze[1], 4_000, "amber is now actually mineable");
    }

    /// A tier's repair must never need a gem the player cannot mine. This is
    /// the dead end the interlock closes: Iron at skill 0 would need Sapphire
    /// for repairs but could never produce it.
    function test_EveryHeldTierIsRepairable() public {
        _grantQuartz(alice, 6_000);
        for (uint8 tier = 1; tier <= 4; tier++) {
            if (tier == 1) {
                _buyTier(alice, 1);
            } else {
                _ensureSkill(alice, tier - 1);
                _breakTool(alice);
                uint256 cost = dw.toolCost(tier);
                vm.prank(alice);
                dw.buyTool{value: cost}(tier);
            }

            // The lowest legal skill for this tier must be able to mine every
            // gem its repair demands.
            uint8 floorSkill = tier > 1 ? tier - 1 : 1;
            uint256[5] memory need = dw.repairNeeds(tier);
            uint256[5] memory table = dw.dropTable(tier, floorSkill);
            for (uint256 r = 0; r < 5; r++) {
                if (need[r] > 0) {
                    assertGt(table[r], 0,
                        "repair needs a gem this tier/skill cannot mine");
                }
            }
        }
    }

    /// The headline guarantee: whatever tier a player holds, a hunt settles.
    /// Under the old design an Iron tool at skill 0 rolled Sapphire, and the
    /// cap check reverted the whole settlement.
    function test_HuntSettlesAtEveryLegalTier() public {
        _grantQuartz(alice, 6_000);
        (, , uint64 cd, , , , ) = dw.getConfig();
        for (uint8 tier = 1; tier <= 4; tier++) {
            if (tier == 1) {
                _buyTier(alice, 1);
            } else {
                _ensureSkill(alice, tier - 1);
                _breakTool(alice);
                uint256 cost = dw.toolCost(tier);
                vm.prank(alice);
                dw.buyTool{value: cost}(tier);
            }
            (uint256[5] memory c, uint256 best) = dw.previewHunt(alice, tier);
            vm.warp(block.timestamp + cd + 1);
            vm.prank(alice);
            dw.settleHunt(alice, tier, c, best, "");
        }
        assertTrue(dw.totalHuntsOf(alice) > 0, "hunts settled at every tier");
    }

    // ---- costs ------------------------------------------------------------

    function test_SkillCostIs200PerLevel() public view {
        assertEq(dw.skillCost(1), 200);
        assertEq(dw.skillCost(2), 400);
        assertEq(dw.skillCost(3), 600);
        assertEq(dw.skillCost(4), 800);
    }

    /// The full unlock is 2,000 Quartz. At the honest phase rates that is
    /// ~1,760 hunts, against ~4,400 at the old 500/level.
    function test_FullUnlockCosts2000Quartz() public {
        uint256 total;
        for (uint8 s = 1; s <= 4; s++) total += dw.skillCost(s);
        assertEq(total, 2_000);
    }

    // ---- stranded players -------------------------------------------------

    /// Players who acquired a tool BEFORE the interlock shipped sit below the
    /// floor (tier 2 at skill 0 -- exactly trader2 on the live contract) and
    /// could not climb. syncSkill brings them up.
    function test_SyncSkillRaisesToTheToolFloor() public {
        // Reproduce the pre-interlock holding through the owner-only migration
        // path, which is the supported way to place a tool outright.
        dw.migrateFromV2(alice, 2, uint64(dw.durabilityOf(2)), [uint256(0), 0, 0, 0, 0]);
        assertEq(dw.skillOf(alice), 0, "legacy player starts at skill 0");

        dw.syncSkill(alice);
        assertEq(dw.skillOf(alice), 1, "raised to the tier-1 floor");
        assertTrue(dw.rarityUnlocked(alice, DeepWoodV4.Rarity.Uncommon), "amber unlocked");

        // Raise-only: calling again must not lower anything.
        dw.syncSkill(alice);
        assertEq(dw.skillOf(alice), 1);
    }

    /// syncSkill can never take a level away, so it cannot confiscate one
    /// anyone bought.
    function test_SyncSkillIsRaiseOnly() public {
        _grantQuartz(alice, 6_000);
        _buyTier(alice, 1);
        _breakTool(alice);
        _ensureSkill(alice, 1);
        uint256 cost = dw.toolCost(2);
        vm.prank(alice);
        dw.buyTool{value: cost}(2);
        assertEq(dw.skillOf(alice), 1);

        dw.syncSkill(alice);
        assertEq(dw.skillOf(alice), 1, "must not lower a purchased level");
    }

    function test_SyncSkillOnlyOwner() public {
        _buyTier(alice, 1);
        vm.prank(alice);
        vm.expectRevert();
        dw.syncSkill(alice);
    }

    // ---- helpers ----------------------------------------------------------

    function _buyTier(address who, uint8 tier) internal {
        uint256 cost = dw.toolCost(tier);
        vm.prank(who);
        dw.buyTool{value: cost}(tier);
    }

    /// Raise skill to `target`, one level per call.
    function _ensureSkill(address who, uint8 target) internal {
        while (dw.skillOf(who) < target) {
            uint8 next = dw.skillOf(who) + 1;
            vm.prank(who);
            dw.upgradeSkill(next);
        }
    }

    /// Wear the held tool down to zero durability by settling hunts.
    function _breakTool(address who) internal {
        (, , uint64 cd, , , , ) = dw.getConfig();
        for (uint256 n = 0; n < 80; n++) {
            (uint8 tier, uint64 dur,) = dw.toolOf(who);
            if (dur == 0) return;
            (uint256[5] memory c, uint256 best) = dw.previewHunt(who, tier);
            vm.warp(block.timestamp + cd + 1);
            vm.prank(who);
            dw.settleHunt(who, tier, c, best, "");
        }
        revert("tool never broke");
    }

    /// Quartz is the only burn currency and minting is owner-only.
    function _grantQuartz(address who, uint256 amount) internal {
        dw.grantGems(who, 0, amount);
    }
}
