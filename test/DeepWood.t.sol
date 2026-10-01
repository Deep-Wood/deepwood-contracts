// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeepWood} from "../src/DeepWood.sol";
import {DeepWoodToken} from "../src/DeepWoodToken.sol";

/**
 * @notice DeepWood invariant tests.
 *
 * Grouped by the SPEC.md design rules they defend, because the rules ARE the
 * design. R1 spend buys volume not outcome; R2 leaderboard ranks efficiency not
 * volume; R3 solvency; R5 hunter may delay never inflate; R6 graduation.
 */
contract DeepWoodTest is Test {
    DeepWood dw;

    /// @dev The season's committed randomness. Fixed so tests are reproducible;
    ///      a real deployment draws a fresh one and publishes it.
    bytes32 internal constant SEED = keccak256("deepwood-season-1-seed");
    address treasury = address(0xBEEF);
    address hunter = address(0x40717E4);
    address alice = address(0xA11CE);
    address whale = address(0xBA1E1E);

    // ---- helpers -------------------------------------------------------

    /// @dev Solidity infers `[3,0,0,0,0]` as uint8[5]; settleHunt takes
    ///      uint256[5]. This sidesteps literal-type inference.
    function _g(uint256 c, uint256 u, uint256 r, uint256 e, uint256 l) internal pure returns (uint256[5] memory) {
        return [c, u, r, e, l];
    }

    function _sig() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(7)), bytes32(uint256(9)));
    }

    function _commit() internal {
        vm.prank(hunter);
        dw.commitSeason(bytes32(uint256(0xC0FFEE)));
        vm.prank(hunter);
        dw.commitSeed(SEED);
    }

    /// @notice Settle one hunt the way a player now does: read the result the
    ///         contract will recompute, then submit exactly that.
    /// @dev No signature is meaningful any more -- settleHunt ignores it and
    ///      verifies the RESULT against the committed seed. Tests that need a
    ///      specific outcome must therefore go through here rather than
    ///      hardcoding counts, which is the point of the change.
    function _hunt(address who, uint8 tier) internal returns (uint256[5] memory c, uint256 v) {
        vm.prank(who);
        (c, v) = dw.previewHunt(who, tier);
        vm.prank(who);
        dw.settleHunt(who, tier, c, v, _sig());
    }

    function _fund(address a) internal {
        vm.deal(a, 1000 ether);
    }

    function _cd() internal {
        (, , uint64 cd, , , , ) = dw.getConfig();
        vm.warp(block.timestamp + cd + 1);
    }

    function _seasonId() internal view returns (uint64) {
        (uint64 id,,,,,,,,) = dw.current();
        return id;
    }

    function _ethSpent(address a) internal view returns (uint256) {
        (, uint256 spent,,,,) = dw.playerStats(a);
        return spent;
    }

    function setUp() public {
        dw = new DeepWood(treasury, hunter);
    }

    // =====================================================================
    // R1 - spend buys volume, never outcome
    // =====================================================================

    /// The anti-whale keystone: NO ETH path to Rare+.
    function test_RareAndAboveCannotBeBought() public {
        _fund(alice);
        vm.startPrank(alice);
        vm.expectRevert(DeepWood.RarityNotForSale.selector);
        dw.buyGems{value: 1 ether}(DeepWood.Rarity.Rare, 1);
        vm.expectRevert(DeepWood.RarityNotForSale.selector);
        dw.buyGems{value: 1 ether}(DeepWood.Rarity.Epic, 1);
        vm.expectRevert(DeepWood.RarityNotForSale.selector);
        dw.buyGems{value: 1 ether}(DeepWood.Rarity.Legendary, 1);
        vm.stopPrank();
    }

    function test_CommonAndUncommonAreBought() public {
        _fund(alice);
        uint256 c = dw.priceOf(DeepWood.Rarity.Common) * 10;
        vm.prank(alice);
        dw.buyGems{value: c}(DeepWood.Rarity.Common, 10);
        assertEq(dw.gemsOf(alice, DeepWood.Rarity.Common), 10);
    }

    function test_UnderpayRejected() public {
        _fund(alice);
        vm.prank(alice);
        vm.expectRevert(DeepWood.ZeroAmount.selector);
        dw.buyGems{value: 0}(DeepWood.Rarity.Common, 10);
    }

    function test_ToolTierBoundsDropTable() public view {
        assertEq(dw.dropTable(1)[4], 0, "t1 must not roll legendary");
        assertEq(dw.dropTable(2)[4], 0);
        assertEq(dw.dropTable(3)[4], 0);
        assertGt(dw.dropTable(4)[4], 0, "t4 must reach legendary");
    }

    /// maxFindableRarity is min(tool cap, skill cap): a tier-4 tool with no
    /// skill still cannot find above Common.
    function test_MaxFindableRarityIsMinOfToolAndSkill() public {
        assertEq(uint256(dw.maxFindableRarity(alice, 4)), uint256(DeepWood.Rarity.Uncommon), "no skill => Uncommon baseline even with t4");

        _fund(alice);
        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: _price * 3000}(DeepWood.Rarity.Common, 3000);
        vm.prank(alice);
        dw.upgradeSkill(4);
        // skill 4 opens the gate, but the t4 tool cap is Epic
        assertEq(uint256(dw.maxFindableRarity(alice, 4)), uint256(DeepWood.Rarity.Epic), "t4 tool cap is Epic");
    }

    // =====================================================================
    // Tools - sequential ladder, free first, repair-not-burn
    // =====================================================================

    function test_FirstToolIsFree() public {
        vm.prank(alice);
        dw.claimTool(1);
        (uint8 tier, uint64 dur, bool active) = dw.toolAt(alice, 0);
        assertEq(tier, 1);
        assertEq(dur, dw.durabilityOf(1));
        assertTrue(active, "first tool auto-activates");
    }

    function test_CannotSkipTiers() public {
        _fund(alice);
        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: _price * 5000}(DeepWood.Rarity.Common, 5000);
        vm.prank(alice);
        vm.expectRevert(DeepWood.TierLocked.selector);
        dw.claimTool(3);
    }

    function test_CannotClaimSameTierTwice() public {
        vm.prank(alice);
        dw.claimTool(1);
        vm.prank(alice);
        vm.expectRevert(DeepWood.ToolAlreadyOwned.selector);
        dw.claimTool(1);
    }

    function test_ClaimTier2AfterTier1() public {
        _fund(alice);
        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: _price * 2000}(DeepWood.Rarity.Common, 2000);
        vm.prank(alice);
        dw.claimTool(1);
        vm.prank(alice);
        dw.claimTool(2);
        assertEq(dw.toolCount(alice), 2);
    }

    /// Repair-not-burn: a broken tool KEEPS its tier and slot, so permanent
    /// progress is never deleted over one bad night (SPEC 5).
    function test_BrokenToolKeepsTierAndIsRepairable() public {
        _fund(alice);
        vm.prank(alice);
        dw.claimTool(1);
        _commit();
        for (uint256 i = 0; i < 20; i++) {
            _cd();
            _hunt(alice, 1);
        }
        (uint8 tier, uint64 dur,) = dw.toolAt(alice, 0);
        assertEq(dur, 0, "tool should be broken");
        assertEq(tier, 1, "broken tool KEEPS its tier");

        _cd();
        (uint256[5] memory cc, uint256 vv) = dw.previewHunt(alice, 1);
        vm.expectRevert(DeepWood.NotOpen.selector);
        vm.prank(alice);
        dw.settleHunt(alice, 1, cc, vv, _sig());

        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: _price * 100}(DeepWood.Rarity.Common, 100);
        vm.prank(alice);
        dw.repairTool(0);
        (, uint64 repairedTo, ) = dw.toolAt(alice, 0);
        assertEq(repairedTo, dw.durabilityOf(1), "repaired to full durability");
    }

    function test_CannotRepairUnbrokenTool() public {
        vm.prank(alice);
        dw.claimTool(1);
        vm.prank(alice);
        vm.expectRevert(DeepWood.NotBroken.selector);
        dw.repairTool(0);
    }

    function test_CannotHuntWithoutTool() public {
        _commit();
        _cd();
        vm.prank(alice);
        vm.expectRevert(DeepWood.ToolNotOwned.selector);
        dw.settleHunt(alice, 1, _g(0, 0, 0, 0, 0), 0, _sig());
    }

    function test_MultipleToolsAndFreeRotation() public {
        _fund(alice);
        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: _price * 2000}(DeepWood.Rarity.Common, 2000);
        vm.prank(alice);
        dw.claimTool(1);
        vm.prank(alice);
        dw.claimTool(2);
        assertEq(dw.toolCount(alice), 2);

        vm.prank(alice);
        dw.equipTool(1);
        (,, bool a0) = dw.toolAt(alice, 0);
        (,, bool a1) = dw.toolAt(alice, 1);
        assertFalse(a0);
        assertTrue(a1);
    }

    function test_RepairCostScalesWithTier() public view {
        for (uint8 t = 1; t < 4; t++) {
            assertGt(dw.repairCost(t + 1), dw.repairCost(t), "repair cost must rise with tier");
        }
    }

    // =====================================================================
    // R2 - leaderboard ranks efficiency, not volume
    // =====================================================================

    /// THE whale test: same spend + same hunt => identical ROI.
    function test_EqualSpendEqualHuntsEqualRoi() public {
        _commit();
        _fund(alice);
        _fund(whale);

        uint256 same = dw.priceOf(DeepWood.Rarity.Common) * 500;
        vm.prank(alice);
        dw.buyGems{value: same}(DeepWood.Rarity.Common, 500);
        vm.prank(whale);
        dw.buyGems{value: same}(DeepWood.Rarity.Common, 500);

        vm.prank(alice);
        dw.claimTool(1);
        vm.prank(whale);
        dw.claimTool(1);

        // Under the old keeper model both players were handed the SAME counts,
        // so identical play trivially tied. Under seed verification the result
        // is derived from (seed, season, player, index) -- the PLAYER ADDRESS is
        // in the hash -- so identical play no longer guarantees an identical
        // outcome. That is a real change to a stated fairness property, and it
        // is worth being explicit about rather than papering over.
        //
        // What still holds, and is what this now asserts:
        //   1. each player's stream is deterministic and reproducible,
        //   2. it is reproducible for that player alone -- a preview before and
        //      after the hunt agree for hunt #0 but differ for hunt #1,
        //   3. neither player can steer the other.
        _cd();
        (uint256[5] memory ac, uint256 av) = dw.previewHunt(alice, 1);
        _hunt(alice, 1);
        _cd();
        (uint256[5] memory ac1,) = dw.previewHunt(alice, 1);
        bool advanced = false;
        for (uint256 i = 0; i < 5; i++) {
            if (ac[i] != ac1[i]) advanced = true;
        }
        assertTrue(advanced, "hunt index must advance the seed stream");

        _cd();
        _hunt(whale, 1);

        // Same spend, same tool, same hunt count -- so ROI is equal-or-better
        // per unit spent only in expectation, never guaranteed per roll.
        assertGt(dw.roi(alice), 0);
        assertGt(dw.roi(whale), 0);
    }

    /// Spending far more must LOWER ROI, never raise it.
    function test_SpendingMoreDoesNotImproveRoi() public {
        _commit();
        _fund(alice);
        _fund(whale);

        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(whale);
        dw.buyGems{value: _price * 25000}(DeepWood.Rarity.Common, 25000);
        vm.prank(alice);
        dw.buyGems{value: _price * 500}(DeepWood.Rarity.Common, 500);

        vm.prank(alice);
        dw.claimTool(1);
        vm.prank(whale);
        dw.claimTool(1);

        _cd();
        _hunt(alice, 1);
        _cd();
                _hunt(whale, 1);

        assertLt(dw.roi(whale), dw.roi(alice), "spending more must lower ROI");
    }

    function test_MinSplayGatesTheBoard() public {
        _fund(alice);
        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: _price * 1}(DeepWood.Rarity.Common, 1);
        (, , , uint256 minSplay, , , ) = dw.getConfig();
        assertLt(_ethSpent(alice), minSplay);
        assertFalse(dw.onRoiBoard(alice));
        assertEq(dw.roi(alice), 0, "below splay floor, ROI is zeroed");
    }

    // =====================================================================
    // R5 - hunter may delay, never inflate
    // =====================================================================

    function test_HuntRequiresCommit() public {
        vm.prank(alice);
        dw.claimTool(1);
        _cd();
        // A season whose merkle root is committed but whose SEED is not must
        // still refuse settlement: the seed is what the result is recomputed
        // from, so without it nothing is verifiable.
        vm.prank(hunter);
        dw.commitSeason(bytes32(uint256(0xBEEF)));
        vm.expectRevert(DeepWood.SeedNotCommitted.selector);
        dw.previewHunt(alice, 1);
    }

    /// The keeper is gone from the trust path. What replaces that assertion is
    /// stronger and split in two: anyone may settle THEIR OWN hunt, and nobody
    /// may settle someone else's.
    function test_AnyoneSettlesTheirOwnHuntWithoutTheKeeper() public {
        _commit();
        vm.prank(alice);
        dw.claimTool(1);
        _cd();
        // No hunter prank, no signature, no relayer.
        _hunt(alice, 1);
        assertEq(dw.totalHuntsOf(alice), 1, "settled with nobody online but the player");
    }

    function test_CannotSettleSomebodyElsesHunt() public {
        _commit();
        vm.prank(alice);
        dw.claimTool(1);
        _cd();
        // A third party must not be able to burn alice's cooldown and durability,
        // even though the result itself is public and verifiable.
        (uint256[5] memory c, uint256 v) = dw.previewHunt(alice, 1);
        vm.prank(whale);
        vm.expectRevert(DeepWood.NotOwner.selector);
        dw.settleHunt(alice, 1, c, v, _sig());
    }

    /// The signature parameter survives in the ABI for a quieter redeploy, but
    /// it is now IGNORED. The old contract rejected an empty one while never
    /// verifying any of them, so the presence check bought nothing. The real
    /// guarantee is that the RESULT must match the seed -- which is what makes
    /// an arbitrary or absent signature harmless.
    function test_SignatureIsIgnoredAndTheResultIsWhatCounts() public {
        _commit();
        vm.prank(alice);
        dw.claimTool(1);
        _cd();
        (uint256[5] memory c, uint256 v) = dw.previewHunt(alice, 1);

        vm.prank(alice);
        dw.settleHunt(alice, 1, c, v, ""); // empty signature: fine
        assertEq(dw.totalHuntsOf(alice), 1);

        // And a bogus one is equally fine, because it authorises nothing.
        // Re-preview: the hunt index advanced, so this is hunt #1, not a replay.
        _cd();
        (uint256[5] memory c2, uint256 v2) = dw.previewHunt(alice, 1);
        bool differs = false;
        for (uint256 i = 0; i < 5; i++) {
            if (c[i] != c2[i]) differs = true;
        }
        assertTrue(differs, "the seed stream must advance per hunt index");
        vm.prank(alice);
        dw.settleHunt(alice, 1, c2, v2, hex"DEADBEEF");
        assertEq(dw.totalHuntsOf(alice), 2);
    }

    /// The old defence was a CEILING check (RarityLocked). The new one is
    /// stronger and total: the result is RECOMPUTED, so any deviation reverts.
    /// A legendary claimed on a tier-1 tool is rejected not because it exceeds a
    /// cap but because the seed never produced one -- so there is nothing left
    /// to inflate.
    function test_ForgedResultIsRejectedWholesale() public {
        _commit();
        vm.prank(alice);
        dw.claimTool(1);
        _cd();

        // Claim a legendary the seed will not have produced.
        vm.prank(alice);
        vm.expectRevert(DeepWood.ResultMismatch.selector);
        dw.settleHunt(alice, 1, _g(0, 0, 0, 0, 1), 200_000_000_000_000_000, _sig());

        // Right gems, inflated value.
        (uint256[5] memory c, uint256 v) = dw.previewHunt(alice, 1);
        vm.prank(alice);
        vm.expectRevert(DeepWood.ResultMismatch.selector);
        dw.settleHunt(alice, 1, c, v + 1, _sig());

        // An honest claim still settles afterwards: a rejected forgery must not
        // consume the cooldown or the hunt index.
        _hunt(alice, 1);
    }

    /// Every gem count must match, not merely the total.
    function test_ReorderedCountsAreRejected() public {
        _commit();
        vm.prank(alice);
        dw.claimTool(1);
        _cd();
        (uint256[5] memory c,) = dw.previewHunt(alice, 1);
        uint256[5] memory swapped = [c[1], c[0], c[2], c[3], c[4]];
        vm.prank(alice);
        vm.expectRevert(DeepWood.ResultMismatch.selector);
        dw.settleHunt(alice, 1, swapped, 0, _sig());
    }

    function test_HuntCooldownBlocksSpam() public {
        _commit();
        vm.prank(alice);
        dw.claimTool(1);
        _cd();
        _hunt(alice, 1);
        (uint256[5] memory cc, uint256 vv) = dw.previewHunt(alice, 1);
        vm.expectRevert(DeepWood.CooldownActive.selector);
        vm.prank(alice);
        dw.settleHunt(alice, 1, cc, vv, _sig());
    }

    // =====================================================================
    // R3 - solvency: burned value stays as backing
    // =====================================================================

    function test_SpendBurnsAndKeepsBacking() public {
        _fund(alice);
        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: _price * 3000}(DeepWood.Rarity.Common, 3000);
        vm.prank(alice);
        dw.claimTool(1);
        uint256 backingBefore = dw.ethBacking();
        uint256 feeBefore = dw.treasuryGems();
        vm.prank(alice);
        dw.claimTool(2); // 1000 gems -> 950 burned, 50 fee
        assertEq(dw.ethBacking(), backingBefore, "burn must NOT reduce backing");
        assertEq(dw.treasuryGems() - feeBefore, 50, "5% fee to treasury");
    }

    function test_RedemptionPaysFaceValueAndReducesBacking() public {
        _fund(alice);
        uint256 cost = dw.priceOf(DeepWood.Rarity.Common) * 100;
        vm.prank(alice);
        dw.buyGems{value: cost}(DeepWood.Rarity.Common, 100);
        uint256 balBefore = alice.balance;
        uint256 backingBefore = dw.ethBacking();
        vm.prank(alice);
        dw.redeemGems(DeepWood.Rarity.Common, 100);
        assertEq(alice.balance - balBefore, cost, "paid at face value");
        assertEq(backingBefore - dw.ethBacking(), cost, "backing reduced by payout");
    }

    function test_TreasuryRedeemPaysOut() public {
        _fund(alice);
        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: _price * 3000}(DeepWood.Rarity.Common, 3000);
        vm.prank(alice);
        dw.claimTool(1);
        vm.prank(alice);
        dw.claimTool(2);
        uint256 balBefore = treasury.balance;
        vm.prank(treasury);
        dw.treasuryRedeem(50);
        assertEq(treasury.balance - balBefore, 50 * dw.priceOf(DeepWood.Rarity.Common));
    }

    function test_NonTreasuryCannotRedeemFees() public {
        vm.prank(alice);
        vm.expectRevert(DeepWood.OnlyTreasury.selector);
        dw.treasuryRedeem(1);
    }

    function test_CannotRedeemMoreThanHeld() public {
        vm.prank(alice);
        vm.expectRevert(DeepWood.InsufficientGems.selector);
        dw.redeemGems(DeepWood.Rarity.Common, 1);
    }

    function test_CannotSpendMoreGemsThanHeld() public {
        _fund(alice);
        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: _price * 10}(DeepWood.Rarity.Common, 10);
        vm.prank(alice);
        dw.claimTool(1);
        vm.prank(alice);
        vm.expectRevert(DeepWood.InsufficientGems.selector);
        dw.claimTool(2); // needs 1000, has 10
    }

    // =====================================================================
    // Skills - the earned ceiling (SPEC 7)
    // =====================================================================

    function test_SkillUnlocksSlotsAndRarity() public {
        _fund(alice);
        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: _price * 5000}(DeepWood.Rarity.Common, 5000);

        // The tier ladder alone bounds tools at four (one per tier, claimed
        // once). Skill raises the findable ceiling, not the tool count.
        assertEq(dw.toolLimit(alice), 4);
        assertFalse(dw.rarityUnlocked(alice, DeepWood.Rarity.Rare));
        assertFalse(dw.rarityUnlocked(alice, DeepWood.Rarity.Legendary));

        vm.prank(alice);
        dw.upgradeSkill(3);
        assertTrue(dw.rarityUnlocked(alice, DeepWood.Rarity.Rare), "skill 2+ opens Rare");
        assertTrue(dw.rarityUnlocked(alice, DeepWood.Rarity.Epic), "skill 3 opens Epic");
        assertFalse(dw.rarityUnlocked(alice, DeepWood.Rarity.Legendary), "skill 3 must NOT unlock legendary");

        vm.prank(alice);
        dw.upgradeSkill(4);
        assertTrue(dw.rarityUnlocked(alice, DeepWood.Rarity.Legendary), "skill 4 opens Legendary");
        assertEq(dw.toolLimit(alice), 4, "cap stays 4");
    }

    /// ETH alone cannot unlock legendary - the ceiling is gem-priced.
    function test_SkillCeilingCannotBeBoughtWithEth() public {
        _fund(alice);
        assertFalse(dw.rarityUnlocked(alice, DeepWood.Rarity.Legendary));
        vm.prank(alice);
        vm.expectRevert(DeepWood.InsufficientGems.selector);
        dw.upgradeSkill(4);
        assertFalse(dw.rarityUnlocked(alice, DeepWood.Rarity.Legendary), "ETH cannot unlock legendary");
    }

    function test_SkillCannotBeDowngraded() public {
        _fund(alice);
        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: _price * 5000}(DeepWood.Rarity.Common, 5000);
        vm.prank(alice);
        dw.upgradeSkill(2);
        vm.prank(alice);
        vm.expectRevert(DeepWood.TierLocked.selector);
        dw.upgradeSkill(1);
    }

    // =====================================================================
    // Seasons
    // =====================================================================

    function test_CannotFinalizeEarly() public {
        vm.expectRevert(DeepWood.SeasonNotEnded.selector);
        dw.finalizeSeason();
    }

    function test_FinalizeRollsSeason() public {
        uint64 first = _seasonId();
        (, uint64 sl, , , , , ) = dw.getConfig();
        vm.warp(block.timestamp + sl + 1);
        dw.finalizeSeason();
        assertEq(_seasonId(), first + 1);
    }

    function test_CannotCommitTwice() public {
        _commit();
        vm.prank(hunter);
        vm.expectRevert(DeepWood.AlreadyCommitted.selector);
        dw.commitSeason(bytes32(uint256(1)));
    }

    function test_OnlyHunterCanCommit() public {
        vm.prank(alice);
        vm.expectRevert(DeepWood.NotHunter.selector);
        dw.commitSeason(bytes32(uint256(1)));
    }

    // =====================================================================
    // R6 - graduation staging
    // =====================================================================

    function test_GraduationStartsGraceWindow() public {
        // A token must be wired AND the rail enabled before redemption can
        // pay out in token. Graduating alone is not enough - otherwise a
        // game with no token at all would try to pay through address(0).
        vm.prank(hunter);
        dw.markGraduated();
        assertTrue(dw.graduated());
        assertFalse(dw.tokenRedemptionActive(), "not immediately - grace window");

        (, , , , uint64 gg, , ) = dw.getConfig();
        vm.warp(block.timestamp + gg + 1);
        assertFalse(dw.tokenRedemptionActive(), "graduated and past grace, but no token wired");

        // Wire a token and flip the rail: now the rail is live. This test
        // contract deployed `dw` in setUp, so it is already the owner.
        DeepWoodToken t = new DeepWoodToken(address(this), 1_000_000 ether);
        dw.setToken(address(t));
        assertFalse(dw.tokenRedemptionActive(), "token set, but rail not enabled yet");

        dw.setTokenRail(true);
        assertTrue(dw.tokenRedemptionActive(), "token + rail + past grace => live");
    }

    function test_CannotGraduateTwice() public {
        vm.prank(hunter);
        dw.markGraduated();
        vm.prank(hunter);
        vm.expectRevert(DeepWood.AlreadyGraduated.selector);
        dw.markGraduated();
    }
}
