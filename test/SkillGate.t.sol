// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {DeepWoodV4} from "../src/DeepWoodV4.sol";

/// @notice The Skill-4 Diamond gate (SPEC section 2).
///
/// Gold is the only tool whose drop table depends on skill. Without Skill 4 the
/// Diamond weight is redistributed to Sapphire, so a Gold hunt can never roll a
/// gem the player is not allowed to keep.
///
/// Why this is its own file: the gate is invisible in the client. The client
/// applies its own Gold/skill-4 table (economy.js dropTable), and before the
/// contract carried the same gate a Gold hunt below skill 4 rolled Diamond
/// on-chain and was then rejected by maxFindableRarity -- a ResultMismatch or
/// RarityLocked revert on a dig the contract itself had produced. The existing
/// roll-parity vectors cover tiers 1-4 only, so nothing caught it.
///
/// Everything is asserted through the PUBLIC preview path (previewHunt /
/// previewHuntAt), because that is exactly what the client reads and submits.
/// The season is opened by the V4 constructor.
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

    // ---- the table itself -------------------------------------------------

    /// The un-gated Gold row is unchanged; the gated row removes Diamond and
    /// moves its 200 weight onto Sapphire, so both rows still sum to 10,000.
    function test_GoldTableIsDiamondFreeBelowSkill4() public view {
        uint256[5] memory gated = dw.dropTable(5, 3);
        assertEq(gated[0], 3_000, "quartz");
        assertEq(gated[1], 3_000, "amber");
        assertEq(gated[2], 3_000, "sapphire absorbs the diamond weight");
        assertEq(gated[3], 1_000, "ruby");
        assertEq(gated[4], 0, "no diamond below skill 4");

        uint256[5] memory full = dw.dropTable(5, 4);
        assertEq(full[4], 200, "skill 4 restores the 2% diamond rate");

        uint256 sum;
        for (uint256 i = 0; i < 5; i++) sum += gated[i];
        assertEq(sum, 10_000, "gated row must still be a 10k distribution");
    }

    /// Only Gold is gated. Every tier below it must return an identical row
    /// whatever the skill, or a low-skill player would be quietly nerfed on
    /// tools the spec says nothing about.
    function test_LowerTiersIgnoreSkill() public view {
        for (uint8 t = 1; t <= 4; t++) {
            uint256[5] memory a = dw.dropTable(t, 1);
            uint256[5] memory b = dw.dropTable(t, 4);
            for (uint256 i = 0; i < 5; i++) {
                assertEq(a[i], b[i], "a tier below Gold must not depend on skill");
            }
        }
    }

    // ---- the roll, through the preview the client uses ---------------------

    /// The heart of it: at every offset, a Gold preview below skill 4 must
    /// NEVER show a Diamond. Swept rather than sampled once -- a single offset
    /// agreeing proves only that that offset happened not to hit the gated
    /// rarity.
    function test_GoldPreviewNeverShowsDiamondBelowSkill4() public {
        // The ladder forces skill 3 by the time a player legally holds Gold:
        // an Iron (tier 3) tool can roll Sapphire, which needs skill 2 to keep,
        // and Steel (tier 4) can roll Ruby, needing skill 3. So skill 3 is the
        // LOWEST skill a Gold holder can actually have, and it is the case that
        // matters. Skills 1 and 2 are covered directly by the table tests.
        _buyGold(alice, 3);
        assertEq(dw.skillOf(alice), 3);
        _assertNoDiamondAcross(alice, "skill 3");
    }

    /// And the inverse: at skill 4 the Diamond band is reachable, so the gate
    /// is a gate and not an accidental removal of the rarity entirely.
    function test_GoldPreviewCanShowDiamondAtSkill4() public {
        _buyGold(alice, 4);
        assertEq(dw.skillOf(alice), 4);

        bool sawDiamond;
        for (uint256 off = 0; off < 2_000; off++) {
            (uint256[5] memory c,) = dw.previewHuntAt(alice, 5, off);
            if (c[4] > 0) {
                sawDiamond = true;
                break;
            }
        }
        assertTrue(sawDiamond, "skill 4 must be able to roll a diamond");
    }

    /// A settled Gold hunt below skill 4 must go through cleanly. This is the
    /// end-to-end shape of the original bug: the roll produced Diamond and the
    /// cap check reverted a settlement the contract had just authorised.
    function test_GoldSettlementSucceedsBelowSkill4() public {
        _buyGold(alice, 3);
        (, , uint64 cd, , , , ) = dw.getConfig();

        (uint256[5] memory c, uint256 best) = dw.previewHunt(alice, 5);
        assertEq(c[4], 0, "no diamond in a skill-3 gold preview");

        vm.warp(block.timestamp + cd + 1);
        vm.prank(alice);
        dw.settleHunt(alice, 5, c, best, "");
        assertEq(dw.totalHuntsOf(alice) > 0, true, "the gold hunt settled");
    }

    /// maxFindableRarity must agree with the roll it is guarding. If the cap
    /// were derived from the FULL Gold table while the roll used the gated one,
    /// the cap would still permit a Diamond -- and the two would be describing
    /// different games.
    function test_CapAgreesWithTheGatedTable() public {
        _buyGold(alice, 3);
        // skill 3: the gated table tops out at Ruby (3), not Diamond (4).
        assertEq(uint256(dw.maxFindableRarity(alice, 5)), 3, "gated cap is Ruby");

        _ensureSkill(alice, 4);
        assertEq(uint256(dw.maxFindableRarity(alice, 5)), 4, "skill 4 lifts the cap");
    }

    // ---- helpers ----------------------------------------------------------

    function _assertNoDiamondAcross(address who, string memory label) internal view {
        for (uint256 off = 0; off < 2_000; off++) {
            (uint256[5] memory c,) = dw.previewHuntAt(who, 5, off);
            assertEq(c[4], 0, string.concat("gold preview showed a diamond at ", label));
            uint256 total;
            for (uint256 r = 0; r < 5; r++) total += c[r];
            assertTrue(total >= 1 && total <= 5, "one rarity, 1-5 copies");
        }
    }

    /// Climb the ladder to Gold, ending at `finalSkill`.
    ///
    /// The climb is NOT tool-only: skill gates which rarities may be KEPT, so
    /// wearing a tier-3 tool down requires skill 2 (Iron can roll Sapphire) and
    /// a tier-4 tool requires skill 3 (Steel can roll Ruby). Hunting with a
    /// tool whose table outruns your skill reverts RarityLocked -- which is the
    /// design working, and the reason this helper raises skill in step.
    ///
    /// NOTE: the tool cost is read into a LOCAL before `vm.prank`. Writing
    /// `dw.buyTool{value: dw.toolCost(t)}(t)` looks equivalent but is not --
    /// argument evaluation performs the toolCost call first, which consumes the
    /// prank, so buyTool executes as the test contract and the tool lands on
    /// the wrong address (toolOf(player) then reads 0,0,false).
    function _buyGold(address who, uint8 finalSkill) internal {
        // From level 0: 500 + 1000 + 1500 + 2000 = 5,000 Quartz to reach 4.
        _grantQuartz(who, 6_000);
        for (uint8 t = 1; t <= 5; t++) {
            if (t == 3) _ensureSkill(who, 2);
            if (t == 4) _ensureSkill(who, 3);
            uint256 cost = dw.toolCost(t);
            vm.prank(who);
            dw.buyTool{value: cost}(t);
            if (t < 5) _breakTool(who);
        }
        _ensureSkill(who, finalSkill);
        (uint8 tier,,) = dw.toolOf(who);
        assertEq(tier, 5, "climbed to gold");
    }

    /// Raise skill to `target`, one level per call.
    ///
    /// skillOf starts at 0, NOT 1. A brand-new player is level 0 and
    /// maxFindableRarity treats "below 2" as the Amber ceiling, so level 0 and
    /// level 1 play identically -- which means upgradeSkill(1) costs 500 Quartz
    /// and grants nothing. Raise to the level the climb actually needs (2 or 3)
    /// rather than climbing through 1 for its own sake.
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
        for (uint256 n = 0; n < 60; n++) {
            (uint8 tier, uint64 dur,) = dw.toolOf(who);
            if (dur == 0) return;
            (uint256[5] memory c, uint256 best) = dw.previewHunt(who, tier);
            vm.warp(block.timestamp + cd + 1);
            vm.prank(who);
            dw.settleHunt(who, tier, c, best, "");
        }
        revert("tool never broke");
    }

    /// Quartz is the only burn currency and minting is owner-only, so the test
    /// funds the player through the owner-facing grant path.
    function _grantQuartz(address who, uint256 amount) internal {
        dw.grantGems(who, 0, amount);
    }
}
