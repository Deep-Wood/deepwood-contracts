// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeepWood} from "../src/DeepWood.sol";

/**
 * @notice DeepWood invariant tests.
 *
 * Grouped by the SPEC.md design rules they defend, because the rules ARE the
 * design. R1 spend buys volume not outcome; R2 leaderboard ranks efficiency not
 * volume; R3 solvency; R5 hunter may delay never inflate; R6 graduation.
 */
contract DeepWoodTest is Test {
    DeepWood dw;
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
    }

    function _fund(address a) internal {
        vm.deal(a, 1000 ether);
    }

    function _cd() internal {
        vm.warp(block.timestamp + dw.HUNT_COOLDOWN() + 1);
    }

    function _seasonId() internal view returns (uint64) {
        (uint64 id,,,,,,) = dw.current();
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
            vm.prank(hunter);
            dw.settleHunt(alice, 1, _g(3, 0, 0, 0, 0), 1, _sig());
        }
        (uint8 tier, uint64 dur,) = dw.toolAt(alice, 0);
        assertEq(dur, 0, "tool should be broken");
        assertEq(tier, 1, "broken tool KEEPS its tier");

        _cd();
        vm.prank(hunter);
        vm.expectRevert(DeepWood.NotOpen.selector);
        dw.settleHunt(alice, 1, _g(3, 0, 0, 0, 0), 1, _sig());

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
        vm.prank(hunter);
        vm.expectRevert(DeepWood.ToolNotOwned.selector);
        dw.settleHunt(alice, 1, _g(3, 0, 0, 0, 0), 1, _sig());
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

        // Fresh players may find Common and Uncommon (the free baseline), so
        // this identical find is legal for both and must score identically.
        _cd();
        vm.prank(hunter);
        dw.settleHunt(alice, 1, _g(5, 1, 0, 0, 0), 1, _sig());
        _cd();
        vm.prank(hunter);
        dw.settleHunt(whale, 1, _g(5, 1, 0, 0, 0), 1, _sig());

        assertEq(dw.roi(alice), dw.roi(whale), "identical play must tie on ROI");
        assertGt(dw.roi(alice), 0);
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
        vm.prank(hunter);
        dw.settleHunt(alice, 1, _g(4, 0, 0, 0, 0), 1, _sig());
        _cd();
        vm.prank(hunter);
        dw.settleHunt(whale, 1, _g(4, 0, 0, 0, 0), 1, _sig());

        assertLt(dw.roi(whale), dw.roi(alice), "spending more must lower ROI");
    }

    function test_MinSplayGatesTheBoard() public {
        _fund(alice);
        uint256 _price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: _price * 1}(DeepWood.Rarity.Common, 1);
        assertLt(_ethSpent(alice), dw.MIN_SPLAY());
        assertFalse(dw.onRoiBoard(alice));
        assertEq(dw.roi(alice), 0, "below splay floor, ROI is zeroed");
    }

    // =====================================================================
    // R5 - hunter may delay, never inflate
    // =====================================================================

    function test_HuntRequiresCommit() public {
        vm.prank(hunter);
        vm.expectRevert(DeepWood.NotCommitted.selector);
        dw.settleHunt(alice, 1, _g(3, 0, 0, 0, 0), 1, _sig());
    }

    function test_OnlyHunterSettles() public {
        _commit();
        vm.prank(alice);
        vm.expectRevert(DeepWood.NotHunter.selector);
        dw.settleHunt(alice, 1, _g(3, 0, 0, 0, 0), 1, _sig());
    }

    function test_HuntSignatureRequired() public {
        _commit();
        vm.prank(alice);
        dw.claimTool(1);
        _cd();
        vm.prank(hunter);
        vm.expectRevert(DeepWood.BadSignature.selector);
        dw.settleHunt(alice, 1, _g(3, 0, 0, 0, 0), 1, "");
    }

    /// The hunter cannot inflate a find above the player's tool+skill ceiling.
    function test_HunterCannotInflateBeyondCeiling() public {
        _commit();
        vm.prank(alice);
        dw.claimTool(1);
        _cd();
        vm.prank(hunter);
        vm.expectRevert(DeepWood.RarityLocked.selector);
        dw.settleHunt(alice, 1, _g(0, 0, 0, 0, 1), 999999, _sig());
    }

    function test_HuntCooldownBlocksSpam() public {
        _commit();
        vm.prank(alice);
        dw.claimTool(1);
        _cd();
        vm.prank(hunter);
        dw.settleHunt(alice, 1, _g(3, 0, 0, 0, 0), 1, _sig());
        vm.prank(hunter);
        vm.expectRevert(DeepWood.CooldownActive.selector);
        dw.settleHunt(alice, 1, _g(3, 0, 0, 0, 0), 1, _sig());
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
        vm.warp(block.timestamp + dw.SEASON_LENGTH() + 1);
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
        vm.prank(hunter);
        dw.markGraduated();
        assertTrue(dw.graduated());
        assertFalse(dw.tokenRedemptionActive(), "not immediately - grace window");
        vm.warp(block.timestamp + dw.GRADUATION_GRACE() + 1);
        assertTrue(dw.tokenRedemptionActive());
    }

    function test_CannotGraduateTwice() public {
        vm.prank(hunter);
        dw.markGraduated();
        vm.prank(hunter);
        vm.expectRevert(DeepWood.AlreadyGraduated.selector);
        dw.markGraduated();
    }
}
