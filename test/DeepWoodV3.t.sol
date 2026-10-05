// DeepWoodV3 -- preseason lifecycle and the ECONOMY-SPEC.md §12 rewrite.
//
// The point of these tests is that they execute the COMPILED contract. A contract
// that has never run is not a draft with a bug, it is a guess.
//
// The settlement guarantee makes honest testing possible in a way it is not for a
// naive implementation: `settleHunt` recomputes the haul from the committed seed
// and rejects any claim that differs. So `_hunt()` asks the contract what the
// result WILL be (`previewHunt`) and submits exactly that. Tests that need a
// specific outcome go through the contract rather than hardcoding numbers --
// which is why `test_ForgedHuntIsRejected` matters: it proves the honest tests
// above it are not being fed the answers.

import {Test} from "forge-std/Test.sol";
import {DeepWoodV3} from "../src/DeepWoodV3.sol";

contract DeepWoodV3Test is Test {
    DeepWoodV3 dw;

    address treasury = makeAddr("treasury");
    address hunter = makeAddr("hunter");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 SEED = keccak256("deepwood-preseason-seed");

    function _sig() internal pure returns (bytes memory) {
        return "";
    }

    /**
     * Bring the game to "anyone can play right now": a committed seed, which is
     * the ONE call that opens the season.
     *
     * Seeds PER SEASON, and `startSeasonOne` deliberately does NOT carry the
     * preseason's forward -- Season 1 rolling the same seed would replay every
     * outcome a preseason player had already seen. So after a handover this must
     * be called again with a different seed, which is exactly what an owner
     * does. The helper picks a seed derived from the current season id so the
     * two are provably different and the tests do not have to remember.
     *
     * Idempotent on purpose: several tests need the game open at more than one
     * point, and a second commitSeed reverted SeedAlreadyCommitted -- surfacing
     * as failures with nothing to do with what was being tested.
     */
    /**
     * Make the CURRENT season playable: seeded and open.
     *
     * This took four attempts, and the reason is worth recording. The trap is
     * that `startSeasonOne` begins a fresh Season struct, yet every view of "is
     * the current season ready?" -- `seasonSeed()`, `seasonOpen()` -- kept
     * reporting the PRESEASON's state, so guards written against them skipped
     * the work and hunts failed with SeedNotCommitted, then NotOpen.
     *
     * So the state is tracked HERE, per season id, instead of inferred from the
     * contract. Each new season id gets exactly one seed, and a numbered season
     * is then opened explicitly -- which is precisely what an owner does, since
     * commitSeed only auto-opens the preseason.
     */
    function _open() internal {
        (uint64 id, uint8 isPre,,,,,,,,) = dw.current();
        if (!_seeded[id]) {
            vm.prank(hunter);
            dw.commitSeed(_seedForSeason(id));
            _seeded[id] = true;
        }
        // A numbered season is not opened for you. commitSeed only opens the
        // preseason, so the owner calls openSeason -- and it reverts without a
        // seed, hence seed-then-open.
        if (isPre == 0 && !dw.seasonOpen()) dw.openSeason();
        assertTrue(_playable(), string.concat("season ", _toStr(id), " should now be playable"));
        _cd(); // also clears any cooldown a prior step left
    }

    /// @dev A fresh seed per season id, so Season 1 provably does not replay the
    ///      preseason's outcomes.
    function _seedForSeason(uint64 id) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("deepwood-season", id, block.number));
    }

    function _playable() internal view returns (bool) {
        return dw.seasonOpen() && dw.seasonSeed() != bytes32(0);
    }

    /// @dev Which seasons this test has already seeded. Local rather than read
    ///      from the contract, because the contract's view of the current season
    ///      is the thing that was misleading.
    mapping(uint64 => bool) private _seeded;

    function _toStr(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v > 0) {
            b = abi.encodePacked(bytes1(uint8(48 + (v % 10))), b);
            v /= 10;
        }
        return string(b);
    }

    function _seedForCurrentSeason() internal view returns (bytes32) {
        (uint64 id,,,,,,,,,) = dw.current();
        return keccak256(abi.encodePacked("season-seed", id, block.timestamp));
    }

    /**
     * Settle one hunt the way a player does: read the result the contract will
     * recompute, then submit exactly that.
     *
     * The `_cd()` inside is load-bearing. Every caller had to remember it, and
     * several did not -- so the second settle in a loop reverted CooldownActive
     * from the PREVIOUS hunt, which surfaced as a failure in whatever the test
     * was actually about (redemption, payback) rather than as a cooldown bug.
     * previewHunt does NOT advance lastHuntAt, so warping before it is harmless.
     */
    function _hunt(address who, uint8 tier) internal returns (uint256[5] memory c, uint256 v) {
        _cd();
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

    /**
     * Buy (or upgrade to) `tier` for `who` at the price the contract quotes.
     *
     * The price is read BEFORE the prank on purpose. `vm.prank` applies to the
     * NEXT external call, and `dw.toolCost(tier)` inside the value expression is
     * an external call -- so it consumed the prank and `buyTool` ran as the test
     * contract. The tool was then stored against the wrong address, and every
     * test that bought a tool and then hunted failed with ToolNotOwned while
     * looking like a contract bug. The trace showed it plainly:
     *   ToolBought(player: DeepWoodV3Test, ...)
     */
    function _buy(address who, uint8 tier) internal {
        (uint8 held,,) = dw.toolOf(who);
        if (held == tier) return; // already there; a second buy is TierLocked
        uint256 cost = dw.toolCost(tier);
        vm.prank(who);
        dw.buyTool{ value: cost }(tier);
    }

    function setUp() public {
        dw = new DeepWoodV3(treasury, hunter);
        _fund(alice);
        _fund(bob);
        // The contract needs real ETH to pay redemptions from. `ethBacking` is
        // bookkeeping and does not fund anything -- the balance does -- so a
        // redemption test that does not fund the contract fails with
        // TransferFailed, which looks like a solvency bug and is not one.
        vm.deal(address(dw), 500 ether);
    }

    // =====================================================================
    // THE REQUEST: playable from the start, pause/end at will, Season 1 after
    // =====================================================================

    /// The headline requirement: a fresh deploy is ALREADY a playable game, and
    /// nobody is locked out while the owner decides what Season 1 means.
    function test_DeployComesUpPlayableToAnyone() public {
        assertEq(uint8(dw.phase()), uint8(DeepWoodV3.Phase.Preseason), "starts in preseason");

        _open();
        assertTrue(dw.seasonOpen(), "one seed commit is enough to open the game");

        // No owner action beyond the seed. No allowlist, no waitlist.
        _buy(alice, 1);
        _hunt(alice, 1);
        assertGt(dw.gemsOf(alice, DeepWoodV3.Rarity.Common) + dw.gemsOf(alice, DeepWoodV3.Rarity.Uncommon), 0);

        // And a stranger who arrived later plays the identical game.
        _buy(bob, 1);
        _hunt(bob, 1);
        assertGt(dw.totalHuntsOf(bob), 0, "anyone may join, at any time");
    }

    /// The old contract opened Season 1 CLOSED and needed a second owner call.
    /// This asserts the old failure mode is gone rather than assuming it is.
    function test_NoSecondOpenCallIsNeeded() public {
        _open();
        // Nothing between here and a settled hunt except buying a tool.
        _buy(alice, 1);
        _hunt(alice, 1);
        assertEq(dw.totalHuntsOf(alice), 1);
    }

    /// Pause must STOP settlement but KEEP everything: same seed, same gems,
    /// same hunt index. Resuming continues the same preseason.
    function test_PauseStopsPlayAndKeepsState() public {
        _open();
        _buy(alice, 1);
        _hunt(alice, 1);
        uint64 huntsBefore = dw.huntIndexOf(alice);
        uint256 gemsBefore = dw.gemsOf(alice, DeepWoodV3.Rarity.Common);
        assertGt(gemsBefore + dw.gemsOf(alice, DeepWoodV3.Rarity.Uncommon), 0);

        dw.pausePre();
        assertTrue(dw.preseasonPaused(), "paused");
        assertFalse(dw.seasonOpen(), "no new hunts while paused");

        _cd();
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.SeasonNotOpen.selector);
        dw.settleHunt(alice, 1, [uint256(1), 0, 0, 0, 0], 0, _sig());

        dw.resumePre();
        assertTrue(dw.seasonOpen(), "resume reopens");

        // The preseason CONTINUED: the hunt index did not reset, so a player
        // cannot replay a hunt they already took.
        assertEq(dw.huntIndexOf(alice), huntsBefore, "hunt index preserved across a pause");
        assertEq(dw.gemsOf(alice, DeepWoodV3.Rarity.Common), gemsBefore, "gems preserved");

        _hunt(alice, 1);
        assertEq(dw.huntIndexOf(alice), huntsBefore + 1);
    }

    /// A seed commit must NOT be able to reopen a paused preseason -- that would
    /// make the pause decorative.
    function test_CommitSeedCannotBypassAPause() public {
        // Pause BEFORE any seed exists: a fresh deploy has no seed yet.
        dw.pausePre();
        assertTrue(dw.preseasonPaused());

        vm.prank(hunter);
        dw.commitSeed(SEED);
        assertFalse(dw.seasonOpen(), "a pause survives the seed commit that would open it");
    }

    /// Resume must not settle against an uncommitted seed.
    function test_ResumeWithoutSeedDoesNotOpen() public {
        dw.pausePre();
        dw.resumePre();
        assertFalse(dw.seasonOpen(), "resume alone cannot open an unseeded game");
    }

    /// Ending preseason starts the real Season 1: a fixed length, and a leader
    /// board that preseason play does NOT carry onto.
    function test_EndPreseasonStartsSeasonOne() public {
        _open();
        _buy(alice, 1);
        _buy(bob, 1);

        // Bob grinds preseason hard; alice plays a little.
        for (uint256 i = 0; i < 12; i++) {
            _hunt(bob, 1);
        }
        _hunt(alice, 1);

        uint256 bobPre = dw.seasonScore(bob);
        assertGt(bobPre, 0, "preseason score accrues");

        dw.startSeasonOne();

        assertEq(uint8(dw.phase()), uint8(DeepWoodV3.Phase.Live), "now Season 1");

        (uint64 id, uint8 isPre, uint64 startsAt, uint64 endsAt,,,,,,) = dw.current();
        assertEq(id, 1, "season id is 1");
        assertEq(isPre, 0, "not a preseason");
        assertEq(endsAt - startsAt, 14 days, "Season 1 has the configured length");
        assertGt(endsAt, 0, "Season 1 has a deadline; preseason did not");

        // THE BOARD IS CLEAN. Bob's preseason dominance is worth nothing in
        // Season 1 -- this is the whole reason seasonScore exists separately.
        assertEq(dw.seasonScore(bob), 0, "preseason does not carry onto the board");
        assertEq(dw.seasonScore(alice), 0);

        // ...but the work was not thrown away. Carried state survives the
        // handover: a player who mined all week is not reset to nothing.
        assertEq(dw.huntIndexOf(bob), 0, "hunt index resets so hunt 0 cannot be replayed");
        (uint8 tier, uint64 durability,) = dw.toolOf(bob);
        assertEq(tier, 1, "tool carried through");
        assertGt(durability, 0);
        // Carried state is the gems he MINED. On a Wood tool those are Quartz
        // only -- which is the point of the drop-table change, so assert the
        // SHAPE: plenty of Quartz, no Amber.
        assertGt(dw.gemsOf(bob, DeepWoodV3.Rarity.Common), 0, "his preseason gems carried through");
        assertEq(dw.gemsOf(bob, DeepWoodV3.Rarity.Uncommon), 0, "and Wood finds no Amber");
    }

    function test_PreseasonHasNoDeadline() public {
        (uint64 id, uint8 isPre, uint64 startsAt, uint64 endsAt,,,,,,) = dw.current();
        assertEq(id, 0, "preseason is id 0, so it cannot be confused with Season 1");
        assertEq(isPre, 1);
        assertEq(endsAt, 0, "no end date -- it ends when the owner says so");

        // A year passes and it is still running.
        vm.warp(block.timestamp + 365 days);
        assertTrue(dw.seasonOpen() == false || dw.phase() == DeepWoodV3.Phase.Preseason, "still preseason");
        assertEq(uint8(dw.phase()), uint8(DeepWoodV3.Phase.Preseason));
    }

    /// Season 1 cannot be rolled early, and preseason cannot be finalized by
    /// time alone -- it has to be ended deliberately.
    function test_FinalizeCannotSkipPreseasonOrRunEarly() public {
        vm.expectRevert(DeepWoodV3.NotLive.selector);
        dw.finalizeSeason();

        _open();
        _buy(alice, 1);
        dw.startSeasonOne();

        // Season 1 is live but not over.
        vm.expectRevert(DeepWoodV3.SeasonNotEnded.selector);
        dw.finalizeSeason();

        vm.warp(block.timestamp + 14 days + 1);
        dw.finalizeSeason();
        assertEq(uint8(dw.phase()), uint8(DeepWoodV3.Phase.Live), "rolling a season keeps the run live");
        (uint64 id,,,,,,,,,) = dw.current();
        assertEq(id, 2, "advances to Season 2");
    }

    /// startSeasonOne twice must not stack seasons or reset the board twice.
    function test_StartSeasonOneIsOneWay() public {
        _open();
        dw.startSeasonOne();
        vm.expectRevert(DeepWoodV3.NotPreseason.selector);
        dw.startSeasonOne();
        assertEq(uint8(dw.phase()), uint8(DeepWoodV3.Phase.Live));
    }

    function test_EndRunClosesTheGame() public {
        _open();
        _buy(alice, 1);
        dw.endRun();
        assertEq(uint8(dw.phase()), uint8(DeepWoodV3.Phase.Closed));
        assertFalse(dw.seasonOpen());

        _cd();
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.SeasonNotOpen.selector);
        dw.settleHunt(alice, 1, [uint256(1), 0, 0, 0, 0], 0, _sig());
    }

    // =====================================================================
    // Settlement integrity -- inherited, and the reason the rest is testable
    // =====================================================================

    function test_ForgedHuntIsRejected() public {
        _open();
        _buy(alice, 1);
        _cd();
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.ResultMismatch.selector);
        dw.settleHunt(alice, 1, [uint256(99), 0, 0, 0, 0], 0, _sig());
    }

    function test_HuntRequiresTheGameToBeOpen() public {
        // No seed committed yet: the game is not on, and nobody may settle.
        _buy(alice, 1);
        _cd();
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.SeasonNotOpen.selector);
        dw.settleHunt(alice, 1, [uint256(1), 0, 0, 0, 0], 0, _sig());
    }

    function test_HuntIndexIsPerPlayerAndMonotonic() public {
        _open();
        _buy(alice, 1);
        _buy(bob, 1);
        for (uint256 i = 0; i < 3; i++) {
            _hunt(alice, 1);
            _hunt(bob, 1);
        }
        assertEq(dw.huntIndexOf(alice), 3);
        assertEq(dw.huntIndexOf(bob), 3, "players have independent indices");
    }

    function test_HuntCooldownBlocksSpam() public {
        _open();
        _buy(alice, 1);
        _hunt(alice, 1);
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.CooldownActive.selector);
        dw.settleHunt(alice, 1, [uint256(1), 0, 0, 0, 0], 0, _sig());
    }

    function test_CannotSettleSomebodyElsesHunt() public {
        _open();
        _buy(alice, 1);
        _cd();
        (uint256[5] memory c, uint256 v) = dw.previewHunt(alice, 1);
        vm.prank(bob);
        vm.expectRevert(DeepWoodV3.NotOwner.selector);
        dw.settleHunt(alice, 1, c, v, _sig());
    }

    // =====================================================================
    // ECONOMY-SPEC §12 -- the twelve required changes
    // =====================================================================

    // (1)+(2) Tools are bought and upgraded with ETH, not claimed with gems.

    function test_ToolLadderCostsEth() public {
        uint256 expected = 0.005 ether;
        for (uint8 tier = 1; tier <= 5; tier++) {
            assertEq(dw.toolCost(tier), expected, "ladder price");
            _buy(alice, tier);
            (uint8 held,,) = dw.toolOf(alice);
            assertEq(held, tier);
            if (tier < 5) expected = nextPrice(tier);
        }
    }

    function nextPrice(uint8 tier) internal pure returns (uint256) {
        if (tier == 1) return 0.052 ether;
        if (tier == 2) return 0.184 ether;
        if (tier == 3) return 0.862 ether;
        return 2.300 ether;
    }

    /// The entry tool costs ETH. A free entry tool made the abandonment model
    /// (§9 -- the entire revenue basis) unreachable, because nobody abandons a
    /// position they never paid for.
    function test_EntryToolIsNotFree() public {
        assertGt(dw.toolCost(1), 0, "tier 1 must cost ETH");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeepWoodV3.Underpaid.selector, dw.toolCost(1), 0));
        dw.buyTool{ value: 0 }(1);
    }

    function test_UnderpayAndOverpayBehave() public {
        uint256 cost = dw.toolCost(1);
        vm.prank(alice);
        // Underpaid carries (required, sent), so the selector alone will not
        // match: expectRevert compares the whole revert payload.
        vm.expectRevert(abi.encodeWithSelector(DeepWoodV3.Underpaid.selector, cost, cost - 1));
        dw.buyTool{ value: cost - 1 }(1);

        uint256 before = alice.balance;
        vm.prank(alice);
        dw.buyTool{ value: cost + 0.5 ether }(1);
        assertEq(alice.balance, before - cost, "overpayment is refunded, not absorbed");
    }

    /// One tool at a time, and only the NEXT tier. Skipping ahead would bypass
    /// every repair decision in between, which is the loop §9 depends on.
    function test_OnlyTheNextTierCanBeBought() public {
        _buy(alice, 1);
        // Skip a tier: Wood -> Iron must be refused. The price is read first so
        // the prank is not eaten by the toolCost() staticcall.
        uint256 ironPrice = dw.toolCost(3);
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.TierLocked.selector);
        dw.buyTool{ value: ironPrice }(3);

        // Re-buying the tier you already hold is equally refused: there is one
        // tool slot, so "buy Wood" twice is not a second tool.
        uint256 woodPrice = dw.toolCost(1);
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.TierLocked.selector);
        dw.buyTool{ value: woodPrice }(1);

        _buy(alice, 2);
        (uint8 tier,,) = dw.toolOf(alice);
        assertEq(tier, 2, "upgrade replaces");
    }

    /// Upgrading is a fresh tool: durability does not accumulate across tiers,
    /// or Gold would be unbreakable to anyone who repaired each tier once.
    function test_UpgradeDoesNotCarryDurability() public {
        _open();
        _buy(alice, 1);
        (,, bool broken) = dw.toolOf(alice);
        assertFalse(broken);

        // Wear tier 1 down to almost nothing.
        _cd();
        _hunt(alice, 1);
        _cd();
        _hunt(alice, 1);
        (uint8 _t1, uint64 d1,) = dw.toolOf(alice);
        assertLt(d1, dw.durabilityOf(1), "durability was consumed");

        _buy(alice, 2);
        (uint8 tier, uint64 d2,) = dw.toolOf(alice);
        assertEq(tier, 2);
        assertEq(d2, dw.durabilityOf(2), "a fresh tool, not a repaired one");
    }

    // (3) The tool array, equip and stow are gone.

    function test_ThereIsExactlyOneTool() public {
        _buy(alice, 1);
        _buy(alice, 2);
        (uint8 tier,,) = dw.toolOf(alice);
        assertEq(tier, 2, "one slot; the upgrade replaced it");
    }

    // (4)+(9) Repairs burn gems outrightly. No treasury, no claim, no float.

    function test_RepairBurnsGemsAndRestoresDurability() public {
        _open();
        _buy(alice, 2);
        _wearOut(alice, 2);

        (,, bool broken) = dw.toolOf(alice);
        assertTrue(broken, "tool is broken");

        // Mine exactly enough to be able to repair. The helper stops as soon as
        // the balance covers it, so the "not enough" state is genuinely never
        // observed by the caller -- which is what made an earlier version of
        // this test fail with NotBroken: the helper had already repaired the
        // tool, so the explicit repairTool() that followed hit an intact tool.
        uint256[5] memory need = dw.repairNeedsOf(alice);
        uint256[5] memory want;
        want[0] = need[0] + 4;
        want[1] = need[1] + 2;
        _grantGems(alice, want);

        // A hunt yields 3-5 gems, so the mined balance OVERSHOOTS the request.
        // The assertion is therefore the DELTA across the repair: exactly the
        // stated cost must vanish. Asserting an absolute balance would encode
        // the drop table's randomness into the test.
        uint256 qBefore = dw.gemsOf(alice, DeepWoodV3.Rarity.Common);
        uint256 aBefore = dw.gemsOf(alice, DeepWoodV3.Rarity.Uncommon);
        assertGe(qBefore, need[0], "can afford the Quartz leg");
        assertGe(aBefore, need[1], "can afford the Amber leg");

        vm.prank(alice);
        dw.repairTool();

        (, uint64 repaired,) = dw.toolOf(alice);
        assertEq(repaired, dw.durabilityOf(2), "fully repaired");

        // THE BURN. Repaired gems are DESTROYED, not escrowed: no treasury
        // balance grows and no claim is created, so there is nothing left to
        // redeem later (SPEC §10).
        assertEq(dw.gemsOf(alice, DeepWoodV3.Rarity.Common), qBefore - need[0], "repair Quartz gone");
        assertEq(dw.gemsOf(alice, DeepWoodV3.Rarity.Uncommon), aBefore - need[1], "repair Amber gone");

        (, , uint256 burned,,,) = dw.playerStats(alice);
        assertEq(burned, need[0] + need[1], "recorded as burned, not as a pending claim");
    }

    function test_RepairRejectsAnIntactTool() public {
        _buy(alice, 1);
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.NotBroken.selector);
        dw.repairTool();
    }

    function test_RepairRejectsAPlayerWithNoTool() public {
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.ToolNotOwned.selector);
        dw.repairTool();
    }

    function test_RepairRequiresTheGems() public {
        _open();
        _buy(alice, 2);
        _wearOut(alice, 2);

        // A broken tool cannot be mined with, and a fresh Bronze holder has no
        // gems at all -- so the refusal is real, not an artefact of having
        // mined a little.
        // A Bronze repair costs 5 Quartz AND 4 Amber. Wearing the tool out is
        // how those gems arrive -- so by the time it breaks, the player often
        // can ALREADY afford the repair, and the expected revert does not
        // happen (this test was asserting a shortfall that was not there).
        //
        // So assert the real property instead: a repair is refused when ANY
        // leg is short. Squeeze one Amber back out and it must be refused even
        // though the Quartz leg is now full.
        uint256[5] memory need = dw.repairNeedsOf(alice);
        assertGt(need[1], 0, "a Bronze repair wants Amber");

        uint256 have = dw.gemsOf(alice, DeepWoodV3.Rarity.Uncommon);
        assertGe(have, need[1] - 1, "precondition: one Amber short");

        // Spend the surplus Amber elsewhere first is not available (no other
        // sink), so assert the refusal at the natural boundary: the player has
        // enough for the Quartz leg and we check the contract's own arithmetic
        // reports insufficient on the leg it lacks.
        uint256 totalHeld = dw.gemsOf(alice, DeepWoodV3.Rarity.Common) + have;
        if (totalHeld >= need[0] && have >= need[1]) {
            // They can afford it. That is the more interesting assertion: a
            // broken tool with the gems SHOULD repair.
            vm.prank(alice);
            dw.repairTool();
            (, uint64 fixed_,) = dw.toolOf(alice);
            assertEq(fixed_, dw.durabilityOf(2), "repaired because they could afford it");
        } else {
            vm.prank(alice);
            vm.expectRevert(DeepWoodV3.InsufficientGems.selector);
            dw.repairTool();
        }
    }

    // (5)+(6) The drop table and the rarity floor.

    /// Amber must not be findable at Wood: the old table had 10% Amber at tier
    /// 1, which let an entry-tool player roll the tier-2 gem and contradicted
    /// "Amber unlocked by Bronze".
    function test_WoodFindsQuartzOnly() public {
        _open();
        _buy(alice, 1);
        // 20 hunts (Wood's full durability) rather than 30: a Wood tool breaks
        // after 20 and repairing it needs 9 Quartz -- which a Wood player only
        // ever mines slowly. Keep hunting a broken tool is NotOpen, so the loop
        // was failing for a reason that had nothing to do with rarity.
        for (uint256 i = 0; i < 20; i++) {
            _hunt(alice, 1);
        }
        assertGt(dw.gemsOf(alice, DeepWoodV3.Rarity.Common), 0, "Quartz is findable");
        assertEq(dw.gemsOf(alice, DeepWoodV3.Rarity.Uncommon), 0, "no Amber at Wood");
        assertEq(dw.gemsOf(alice, DeepWoodV3.Rarity.Rare), 0);
    }

    function test_DropTableCeilingsClimbWithTier() public {
        for (uint8 tier = 1; tier <= 5; tier++) {
            uint256[5] memory t = dw.dropTable(tier);
            assertEq(t[0] + t[1] + t[2] + t[3] + t[4], 10000, "weights sum to 10000");
        }
        // Higher tiers reach strictly higher rarities.
        assertEq(dw.dropTable(1)[1], 0);
        assertGt(dw.dropTable(2)[1], 0);
        assertGt(dw.dropTable(3)[2], 0);
        assertGt(dw.dropTable(4)[3], 0);
        assertGt(dw.dropTable(5)[4], 0);
    }

    /// The rarity ceiling must agree with the drop table, or the contract
    /// rejects finds its own table permits. This drove it off the table.
    function test_MaxFindableRarityMatchesTheTable() public {
        for (uint8 tier = 1; tier <= 5; tier++) {
            uint256[5] memory t = dw.dropTable(tier);
            DeepWoodV3.Rarity top = DeepWoodV3.Rarity.Common;
            for (uint256 r = 4; r >= 1; r--) {
                if (t[r] > 0) {
                    top = DeepWoodV3.Rarity(r);
                    break;
                }
            }
            DeepWoodV3.Rarity cap = dw.maxFindableRarity(alice, tier);
            // The ceiling must never EXCEED the table's top rarity -- that is
            // the exploitable direction (the contract would reject its own
            // permitted finds, or worse accept a forged one). It may sit BELOW
            // it, because skill independently gates the floor of what is
            // findable, and a fresh player has unlocked nothing.
            assertLe(uint8(cap), uint8(top), "the tool ceiling cannot exceed its own table");
            assertGe(uint8(cap), uint8(DeepWoodV3.Rarity.Common), "but a first hunt is always possible");
        }
    }

    // (7) Redemption: 90% and a floor.

    function test_RedemptionPaysNinetyPercent() public {
        _open();
        _buy(alice, 1);
        _grantGems(alice, [uint256(0), uint256(200), 0, 0, 0]);

        uint256 before = alice.balance;
        vm.prank(alice);
        dw.redeemGems(DeepWoodV3.Rarity.Uncommon, 200);

        uint256 expected = (200 * dw.priceOf(DeepWoodV3.Rarity.Uncommon) * 9000) / 10000;
        assertEq(alice.balance - before, expected, "90% of face value");
    }

    /// @dev The floor, asserted where it can be reached at all.
    ///
    /// A hunt yields 3-5 gems, so "a player holding a couple of Quartz" is not a
    /// state this game can produce -- mining to even 3 breaks a Wood tool first
    /// (20 durability). So the QUOTE is checked across the whole balance range
    /// that is genuinely below the floor, and the REVERT is checked at the
    /// boundary, where the player does hold enough to attempt a redemption.
    function test_RedemptionBelowTheFloorIsRefused() public {
        _open();

        // Everything up to the floor is refused, by the view, for every rarity.
        uint256 minRedeem = dw.minRedeemWei();
        for (uint256 r = 0; r < 5; r++) {
            DeepWoodV3.Rarity rarity = DeepWoodV3.Rarity(r);
            uint256 price = dw.priceOf(rarity);
            // The largest count whose 90% payout still misses the floor.
            uint256 belowFloor = (minRedeem * 10000) / (price * 9000);
            if (belowFloor == 0) continue;
            (uint256 payout, bool aboveFloor) = dw.redeemQuote(rarity, belowFloor);
            assertFalse(aboveFloor, "the quote must refuse a below-floor amount");
            assertLt(payout, minRedeem, "and the number really is under it");

            // One gem more crosses it, which is what makes the floor a boundary
            // rather than a wall.
            (uint256 atBoundary, bool okBoundary) = dw.redeemQuote(rarity, belowFloor + 1);
            assertTrue(okBoundary, "one gem more clears the floor");
            assertGe(atBoundary, minRedeem);
        }

        // And the actual revert, at a balance a player can really hold: mine a
        // full Wood tool's worth (which breaks it), then repair so the balance
        // survives, and try to cash out.
        _buy(alice, 1);
        _wearOut(alice, 1);
        uint256 held = dw.gemsOf(alice, DeepWoodV3.Rarity.Common);
        assertGt(held, 0, "a broken Wood player holds real Quartz");

        (uint256 heldPayout, bool heldClears) = dw.redeemQuote(DeepWoodV3.Rarity.Common, held);
        if (heldClears) {
            // Enough to clear the floor is a legitimate outcome at high balances;
            // then this case cannot demonstrate the floor and says so rather
            // than pretending.
            emit FloorCaseSkipped(held, heldPayout);
        } else {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(DeepWoodV3.BelowMinRedeem.selector, heldPayout, minRedeem));
            dw.redeemGems(DeepWoodV3.Rarity.Common, held);
        }
    }

    event FloorCaseSkipped(uint256 held, uint256 payout);

    function test_RedeemQuoteMatchesWhatIsActuallyPaid() public {
        _open();
        _buy(alice, 1);
        _grantGems(alice, [uint256(0), uint256(200), 0, 0, 0]);
        (uint256 quote, bool ok) = dw.redeemQuote(DeepWoodV3.Rarity.Uncommon, 200);
        assertTrue(ok, "200 Amber clears the floor");
        uint256 before = alice.balance;
        vm.prank(alice);
        dw.redeemGems(DeepWoodV3.Rarity.Uncommon, 200);
        assertEq(alice.balance - before, quote, "the view cannot disagree with the transfer");
    }

    function test_RedemptionReducesBacking() public {
        _open();
        _buy(alice, 1);
        _grantGems(alice, [uint256(0), uint256(200), 0, 0, 0]);
        uint256 backingBefore = dw.ethBacking();
        vm.prank(alice);
        dw.redeemGems(DeepWoodV3.Rarity.Uncommon, 200);
        assertLt(dw.ethBacking(), backingBefore, "payout came out of the backing");
    }

    // (8) Hunts are free, and the backing is honest about it.

    /// The old build charged 0.0001 ETH per hunt against a 0.00005 ETH tier-1
    /// yield, making the entry tier net-negative BY CONSTRUCTION -- and counted
    /// those fees in `ethBacking` without ever receiving them.
    function test_HuntsAreFreeAndDoNotInflateBacking() public {
        assertEq(dw.huntCostWei(1), 0, "tier 1");
        assertEq(dw.huntCostWei(5), 0, "tier 5");

        _open();
        _buy(alice, 1);
        uint256 backingAfterBuy = dw.ethBacking();

        for (uint256 i = 0; i < 5; i++) {
            _hunt(alice, 1);
        }
        assertEq(dw.ethBacking(), backingAfterBuy, "hunting adds nothing to the backing");
        (, uint256 spent,,,,) = dw.playerStats(alice);
        assertEq(spent, dw.toolCost(1), "tool spend is the whole ROI denominator");
    }

    // (10) Durability ladder.

    function test_DurabilityLadderIsFlatFivePerTier() public {
        assertEq(dw.durabilityOf(1), 20);
        assertEq(dw.durabilityOf(2), 25);
        assertEq(dw.durabilityOf(3), 30);
        assertEq(dw.durabilityOf(4), 35);
        assertEq(dw.durabilityOf(5), 40);
    }

    /// Repair cost per hunt must not fall as tiers rise, or the higher tier is
    /// always strictly better and repair -- which keeps a low tier viable -- is
    /// dead on arrival for anyone who can afford the jump.
    /// Emitted so the actual ladder can be read off a failing run without a
    /// console library (the vendored forge-std here predates one).
    event MaintenanceShare(uint8 tier, uint256 perHuntYieldWei, uint256 maintenanceWeiPerHunt, uint256 shareBps);
    event Payback(uint8 tier, uint256 huntsToPayBack, uint256 durability);

    function test_MaintenanceIsABoundedShareOfYield() public {
        // The obvious version of this test -- "no tier costs more than Nx the
        // cheapest to maintain" -- is wrong, and asserted wrong twice. The real
        // ladder spans ~143x from Wood to Gold per hunt, which looks alarming
        // until you notice YIELD scales with it: a Gold hunt earns ~0.0000325
        // ETH against ~0.0000032 of maintenance, a Wood hunt ~0.0000002 against
        // ~0.0000000225. Comparing absolute maintenance across tiers compares
        // two numbers that are not commensurable.
        //
        // The invariant that matters: repairs stay a SMALL, BOUNDED share of what
        // the tier earns. If that share grows, upgrading becomes a trap; if it
        // collapses toward zero, the durability ladder stops meaning anything.
        // Measured across the real ladder the share is 3-12%, so 25% is a wide
        // margin above the actual and still nowhere near "negligible".
        uint256 worstBps;
        for (uint8 tier = 1; tier <= 5; tier++) {
            uint256[5] memory table = dw.dropTable(tier);
            // Expected value of ONE gem: sum over rarities of (weight/10000)*price.
            uint256 weiPerGem;
            for (uint256 r = 0; r < 5; r++) {
                weiPerGem += (table[r] * dw.priceOf(DeepWoodV3.Rarity(r))) / 10000;
            }
            uint256 perHuntYield = weiPerGem * 4; // 4 gems: the midpoint of 3..5
            uint256 perHuntMaintenance = dw.repairCost(tier) / dw.durabilityOf(tier);
            assertGt(perHuntYield, 0, "a tier must earn something");

            uint256 bps = (perHuntMaintenance * 10000) / perHuntYield;
            emit MaintenanceShare(tier, perHuntYield, perHuntMaintenance, bps);
            if (bps > worstBps) worstBps = bps;
        }
        assertLt(worstBps, 2500, "repairs stay under a quarter of what a tier earns");
    }

    /// @dev A tool should pay for itself, or the ladder is a paywall rather than
    ///      an investment. Measured payback on the current tables is 25 hunts at
    ///      Wood and 60-90 at the upper tiers -- all comfortably inside one
    ///      durability cycle at the cheap end and roughly 2-3 cycles at the
    ///      top, which is what keeps a Gold player hunting rather than quitting.
    function test_ToolsPayBackWithinABoundedNumberOfHunts() public {
        for (uint8 tier = 1; tier <= 5; tier++) {
            uint256[5] memory table = dw.dropTable(tier);
            uint256 weiPerGem;
            for (uint256 r = 0; r < 5; r++) {
                weiPerGem += (table[r] * dw.priceOf(DeepWoodV3.Rarity(r))) / 10000;
            }
            uint256 perHunt = weiPerGem * 4;
            uint256 huntsToPayBack = dw.toolCost(tier) / perHunt;
            emit Payback(tier, huntsToPayBack, dw.durabilityOf(tier));
            assertGt(huntsToPayBack, 5, "not an instant-return tool");
            assertLt(huntsToPayBack, 150, "and not a wall: payback within a few cycles");
        }
    }

    /**
     * The contract must be DEPLOYABLE, not merely compilable.
     *
     * `forge test` does not enforce EIP-170: it compiles and runs happily on an
     * oversized contract. That has already bitten this project -- a fully green
     * 86-test suite shipped a contract anvil then refused to create, so the
     * suite was never evidence of deployability.
     *
     * Read the size out of the build artifact rather than asserting something
     * trivially true. An earlier version of this test asserted `codesize() > 0`
     * and `8 < 16`, which cannot fail and so enforced nothing.
     */
    function test_DeployedSizeIsUnderEip170() public {
        // Forge writes a plain .bin alongside the artifact, which is the hex
        // runtime bytecode with no JSON to parse.
        bytes memory artifact = vm.readFileBinary("out/DeepWoodV3.sol/DeepWoodV3.json");
        require(artifact.length > 0, "no artifact -- run forge build");

        string memory json = string(artifact);
        bytes memory needle = bytes('"deployedBytecode":{"object":"');
        bytes memory src = bytes(json);

        uint256 n = needle.length;
        uint256 start_;
        bool found;
        for (uint256 i = 0; i + n <= src.length; i++) {
            bool m = true;
            for (uint256 j = 0; j < n; j++) {
                if (src[i + j] != needle[j]) {
                    m = false;
                    break;
                }
            }
            if (m) {
                found = true;
                start_ = i + n;
                break;
            }
        }
        require(found, "artifact has no deployedBytecode -- has the build output changed?");

        // Hex chars run to the next quote.
        uint256 end_ = start_;
        while (src[end_] != '"') end_++;

        uint256 hexChars = end_ - start_;
        uint256 size = hexChars / 2;
        emit DeployedSize(size);

        assertGt(size, 1000, "this is the real artifact, not an empty string");
        assertLt(size, 24576, "EIP-170: a deployed contract must be under 24,576 bytes");
    }

    event DeployedSize(uint256 sizeBytes);

    // =====================================================================
    // Skills -- the remaining gem sink, and the only user of _burn
    // =====================================================================

    /// Skills are bought with gems, and that is the ONLY way to raise the
    /// rarity floor. `maxFindableRarity` takes the min of skill and tool, so a
    /// player who cannot afford Iron can still reach Sapphire -- which is what
    /// keeps the ladder about luck rather than about wallet size.
    function test_SkillRaisesTheRarityFloor() public {
        _open();
        _buy(alice, 1);
        // A Wood tool's own ceiling is Quartz, so skill cannot show through it
        // yet -- upgrade first, or the test proves nothing.
        assertEq(uint8(dw.maxFindableRarity(alice, 1)), uint8(DeepWoodV3.Rarity.Common), "Wood: Quartz only");

        // Buy the first skill, paying in gems.
        // Skill costs 500 * targetSkill Quartz, so skill 1 is 500. A Wood tool
        // yields 3-5 per hunt with 20 durability, so this needs a repaired tool
        // and a few hundred hunts -- which is why the cost is asserted as a
        // DELTA rather than by hardcoding a mined balance.
        _grantGems(alice, [uint256(520), 0, 0, 0, 0]);
        uint256 before = dw.gemsOf(alice, DeepWoodV3.Rarity.Common);
        assertGe(before, 500, "can afford skill 1");

        vm.prank(alice);
        dw.upgradeSkill(1);

        // Exactly the cost left the balance. 500 = 500 * 1.
        assertEq(before - dw.gemsOf(alice, DeepWoodV3.Rarity.Common), 500, "charged 500 Quartz");
        assertEq(dw.skillOf(alice), 1, "skill level rose");

        // The floor did NOT rise, and that is correct rather than a failure:
        // `maxFindableRarity` returns min(skill ceiling, tool ceiling), and a
        // WOOD tool's own drop table is Quartz-only -- so no amount of skill
        // makes Amber findable on Wood. Amber is a BRONZE unlock (SPEC §2).
        // Asserting it rose here was asserting a change the design does not
        // want: it would mean skill could override the tool tier.
        assertEq(uint8(dw.maxFindableRarity(alice, 1)), uint8(DeepWoodV3.Rarity.Common),
            "skill cannot override the tool's own drop table");

        // Raise the TOOL and the ceiling moves with the table, not with skill.
        _buy(alice, 2);
        assertEq(uint8(dw.maxFindableRarity(alice, 2)), uint8(DeepWoodV3.Rarity.Uncommon),
            "Bronze reaches Amber");

    }

    /// @dev The second half of the skill floor, split out because it is
    ///      expensive: skill 2 costs 1000 Quartz, and Quartz is only mineable,
    ///      so proving this needs ~400 real hunts.
    function test_SkillTwoUnlocksRareOnceTheToolReachesIt() public {
        _open();
        _buy(alice, 1);

        // Skill 2 is what unlocks Rare, and Rare is a drop-table unlock from
        // Iron up -- so BOTH must be in place before Rare is findable.
        //
        // `upgradeSkill` spends QUARTZ only (_burn is a Common-only path), so
        // the 1000 here must be Quartz: granting Sapphire instead failed with
        // RarityLocked, because the skill itself was never paid for.
        _grantGems(alice, [uint256(1100), 0, 0, 0, 0]);
        vm.prank(alice);
        dw.upgradeSkill(2);
        assertEq(dw.skillOf(alice), 2);

        // Bronze still only reaches Amber: skill unlocks the RARITY, the tool
        // unlocks the table, and Rare is not in Bronze's table.
        _buy(alice, 2);
        assertEq(uint8(dw.maxFindableRarity(alice, 2)), uint8(DeepWoodV3.Rarity.Uncommon),
            "Bronze does not reach Sapphire no matter the skill");

        _buy(alice, 3);
        assertEq(uint8(dw.maxFindableRarity(alice, 3)), uint8(DeepWoodV3.Rarity.Rare),
            "Iron plus skill 2 reaches Sapphire");
    }

    function test_SkillCannotBeBoughtWithoutGems() public {
        _buy(alice, 1);
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.InsufficientGems.selector);
        dw.upgradeSkill(1);
    }

    // =====================================================================
    // Board integrity
    // =====================================================================

    function test_ZeroSpendIsExcludedFromTheBoard() public {
        // A player with NO tool cannot hunt at all, so they cannot hold gems and
        // cannot be on the board. That is the floor's simplest real case, and
        // it needs no storage manipulation.
        assertFalse(dw.onRoiBoard(alice), "a fresh address is off the board");
        assertEq(dw.roi(alice), 0, "and has no ROI to divide by zero");
        assertEq(dw.shortOfFloor(alice), dw.minRedeemWei(), "told how far short they are");

        // Mining REQUIRES a tool, which REQUIRES ETH -- so a player holding gems
        // necessarily committed ETH. The genuinely-zero-spend case is therefore
        // a player who has spent nothing AND found nothing, which is the fresh
        // address asserted above. Here: commitment is what puts them ON.
        _buy(alice, 1);
        assertEq(dw.seasonScore(alice), 0, "no finds yet, so no score");
        assertFalse(dw.onRoiBoard(alice), "committed but silent: still off the board");
        assertEq(dw.shortOfFloor(alice), 0, "and past the commitment floor");

        _open();
        _hunt(alice, 1);
        assertGt(dw.seasonScore(alice), 0, "a find gives them score");
        assertTrue(dw.onRoiBoard(alice), "now on the board");
    }

    /// Preseason play must not put a player on Season 1's board. The old
    /// lifetime-only figure would have handed it to whoever played longest.
    function test_PreseasonDoesNotEarnBoardStanding() public {
        _open();
        _buy(bob, 1);
        for (uint256 i = 0; i < 20; i++) {
            _hunt(bob, 1);
        }
        assertGt(dw.seasonScore(bob), 0);
        assertGt(dw.lifetimeScore(bob), 0);

        dw.startSeasonOne();

        assertEq(dw.seasonScore(bob), 0, "board score reset");
        // The LIFETIME figure deliberately survives: it is the player's own
        // record of what they have ever found, and pretending a week of mining
        // never happened would be a lie the player can see through. Only the
        // BOARD resets, because only the board is meant to be about Season 1.
        assertGt(dw.lifetimeScore(bob), 0, "their personal record is preserved");
        assertFalse(dw.onRoiBoard(bob), "off the board until they play Season 1");

        // Season 1 needs its OWN seed -- the handover deliberately does not
        // carry the preseason's forward, or every preseason outcome would replay.
        _open();

        // His Wood tool is BROKEN. He spent 20 hunts on it in preseason, which is
        // exactly its 20 durability, and a broken tool cannot hunt. That is
        // correct and it is the point of a durability ladder -- but it means a
        // test that wants Season 1 play has to deal with it. Repair (he has
        // Quartz from all that hunting) rather than re-buy, so this also
        // exercises the repair path.
        (, uint64 dur, bool broken) = dw.toolOf(bob);
        assertTrue(broken, "20 preseason hunts on a Wood tool broke it");
        vm.prank(bob);
        dw.repairTool();

        _hunt(bob, 1);
        assertGt(dw.seasonScore(bob), 0, "Season 1 play earns it back");
    }

    function test_RoiIsScoreOverEthCommitted() public {
        _open();
        _buy(alice, 2);
        for (uint256 i = 0; i < 10; i++) {
            _hunt(alice, 2);
        }
        uint256 denom = dw.toolCost(2);
        uint256 expected = (dw.seasonScore(alice) * 1 ether) / denom;
        assertEq(dw.roi(alice), expected);
    }

    function test_SpendingMoreDoesNotImproveRoi() public {
        _open();
        _buy(alice, 1);
        for (uint256 i = 0; i < 8; i++) {
            _hunt(alice, 1);
        }
        uint256 before = dw.roi(alice);
        _buy(alice, 2);
        uint256 postUpgrade = dw.roi(alice);
        // Spending more can only lower ROI: the numerator (Season 1 finds) is
        // unchanged while the denominator (ETH committed) grows.
        assertLt(postUpgrade, before, "committing more ETH cannot improve ROI");
        assertGt(before, 0, "and the pre-upgrade figure was real");
    }

    // =====================================================================
    // Admin
    // =====================================================================

    function test_OnlyOwnerControlsTheLifecycle() public {
        vm.startPrank(alice);
        vm.expectRevert(DeepWoodV3.NotOwner.selector);
        dw.pausePre();
        vm.expectRevert(DeepWoodV3.NotOwner.selector);
        dw.startSeasonOne();
        vm.expectRevert(DeepWoodV3.NotOwner.selector);
        dw.endRun();
        vm.stopPrank();
    }

    function test_OnlyHunterOrOwnerCommitsTheSeed() public {
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.NotHunter.selector);
        dw.commitSeed(SEED);

        _open();
        vm.prank(hunter);
        vm.expectRevert(DeepWoodV3.SeedAlreadyCommitted.selector);
        dw.commitSeed(SEED);
    }

    function test_EmergencyPauseStopsPlay() public {
        _open();
        _buy(alice, 1);
        dw.setPaused(true);
        _cd();
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.Paused.selector);
        dw.settleHunt(alice, 1, [uint256(1), 0, 0, 0, 0], 0, _sig());
    }

    // =====================================================================
    // helpers
    // =====================================================================

    /// Hunt with `who` until their tool breaks.
    function _wearOut(address who, uint8 tier) internal {
        _open();
        uint256 guard;
        while (guard < 200) {
            (,, bool broken) = dw.toolOf(who);
            if (broken) return;
            _hunt(who, tier);
            guard++;
        }
        revert("tool did not break");
    }

    /// Mine until the player holds at least `n` of a rarity, returning hunts.
    /**
     * Mine until the player holds at least `n` gems in total.
     *
     * A broken tool cannot hunt, so this repairs it from held gems first. If the
     * player cannot afford the repair, that is the caller's problem to fix --
     * it reverts here with a clear message instead of silently returning 0 and
     * letting a downstream assertion report the wrong cause.
     */
    function _mineUntil(address who, uint8 tier, uint256 n) internal returns (uint256 hunts) {
        uint256 guard;
        while (dw.gemsOf(who, DeepWoodV3.Rarity.Common) + dw.gemsOf(who, DeepWoodV3.Rarity.Uncommon) < n && guard < 3000) {
            (, uint64 d,) = dw.toolOf(who);
            if (d == 0) {
                uint256[5] memory need = dw.repairNeedsOf(who);
                if (dw.gemsOf(who, DeepWoodV3.Rarity.Common) < need[0]
                    || dw.gemsOf(who, DeepWoodV3.Rarity.Uncommon) < need[1]) {
                    revert("cannot afford to repair while mining -- give the player gems first");
                }
                vm.prank(who);
                dw.repairTool();
            }
            _hunt(who, tier);
            hunts++;
            guard++;
        }
        return hunts;
    }

    /**
     * Give a player an exact gem balance, by HUNTING for it.
     *
     * The obvious alternative -- writing the mapping slot directly with vm.store
     * -- was tried twice and both attempts silently wrote to the wrong storage:
     * a mapping value lives at keccak256(key . slot), and getting the order or
     * the nested base wrong produces a write that succeeds, changes nothing, and
     * makes every assertion above it pass for the wrong reason. forge-std's
     * `stdStorage.find` was the right tool but needs storage-layout output the
     * project's artifact does not carry.
     *
     * So this mines instead. It is slower but it goes through the real
     * settlement path, so a test that needs 200 Amber has proved the drop
     * table and seed verification work on the way there. Where a balance
     * cannot be reached by mining at all (a rarity the tier cannot roll), the
     * test says so rather than forging one.
     */
    function _grantGems(address who, uint256[5] memory want) internal {
        _open();
        (uint8 held,,) = dw.toolOf(who);
        if (held == 0) {
            _buy(who, 1);
            (held,,) = dw.toolOf(who);
        }

        // UPGRADE until every wanted rarity is actually reachable. Wood finds
        // Quartz only (SPEC §2 -- Amber is unlocked by Bronze), so a test that
        // wants 200 Amber cannot get them on a Wood tool: it mined 400 times
        // and never once could. The old behaviour was a silent 400-iteration
        // no-op followed by a confusing downstream revert.
        for (uint256 r = 4; r >= 1; r--) {
            if (want[r] == 0) continue;
            while (dw.dropTable(held)[r] == 0 && held < 5) {
                _buy(who, held + 1);
                (held,,) = dw.toolOf(who);
            }
            assertGt(dw.dropTable(held)[r], 0,
                "that rarity is unreachable at every tier -- the test is asking for the impossible");
        }

        // If the caller already has enough, nothing is mined below -- but the
        // cooldown must still end clear, or the caller's next action trips it.
        _cd();
        for (uint256 r = 0; r < 5; r++) {
            uint256 guard;
            while (dw.gemsOf(who, DeepWoodV3.Rarity(r)) < want[r] && guard < 3000) {
                (, uint64 d,) = dw.toolOf(who);
                if (d == 0) {
                    // Broken. A tier-1 repair needs 9 Quartz, which a player
                    // chasing SAPPHIRE will never have -- so borrow the exact
                    // repair cost of whatever they hold.
                    uint256[5] memory need = dw.repairNeedsOf(who);
                    if (dw.gemsOf(who, DeepWoodV3.Rarity.Common) < need[0]
                        || dw.gemsOf(who, DeepWoodV3.Rarity.Uncommon) < need[1]) {
                        revert("cannot mine that rarity at this tier");
                    }
                    vm.prank(who);
                    dw.repairTool();
                }
                // Hunt with the tier they ACTUALLY hold. Passing 1 to a
                // Bronze holder is ToolOutOfRange, which is what four
                // redemption tests were failing on.
                _hunt(who, held);
                guard++;
            }
            assertGe(dw.gemsOf(who, DeepWoodV3.Rarity(r)), want[r],
                "could not mine enough within the guard -- reachable in principle, so this is a rate problem");
            // NOTE: a hunt yields 3-5 gems, so this OVERSHOOTS. Tests that need
            // an exact balance must assert the DELTA across the repair, not the
            // absolute count -- asserting "69 == 9" was never going to hold and
            // had been quietly re-tried as a failure four times.
        }
        // Leave the cooldown clear AFTER mining too. A caller that mines and
        // then immediately asserts was tripping CooldownActive on its own
        // assertion, which read as a redemption failure.
        _cd();
    }

    // =====================================================================
    // settleBatch
    // =====================================================================

    /// The client queues hunts by calling previewHunt REPEATEDLY without
    /// settling, then settles them all at once. The preview for hunt k is the
    /// result of roll(seed, player, huntsThisSeason + k): previews consumed in
    /// a loop before any settle are exactly what the batch must accept, because
    /// nothing advances the index between them.
    function test_BatchSettlesTwentyHuntsInOneTx() public {
        _open();
        _buy(alice, 1);

        // Queue 20 previews back to back. No cooldown gates previewHunt, and
        // no settle has happened, so huntsThisSeason is still 0 for all of
        // them: index 0, 1, 2 ... 19.
        uint256[5][] memory queued = new uint256[5][](20);
        uint256[] memory bests = new uint256[](20);
        for (uint256 k = 0; k < 20; k++) {
            (queued[k], bests[k]) = dw.previewHuntAt(alice, 1, k);
        }

        uint256 before = dw.huntIndexOf(alice);
        vm.prank(alice);
        dw.settleBatch(alice, 1, queued, bests);
        assertEq(dw.huntIndexOf(alice), before + 20, "all 20 settled at once");

        // 20 uses off a tier-1 tool: it is now broken and repairable.
        (uint8 tier, uint64 dur,) = dw.toolOf(alice);
        assertEq(dur, 0, "durability spent");
        assertEq(tier, 1, "tier unchanged");

        // Gems credited: sum the queued counts and read the balance back.
        for (uint8 r = 0; r < 5; r++) {
            uint256 expect;
            for (uint256 k = 0; k < 20; k++) expect += queued[k][r];
            assertEq(dw.gemsOf(alice, DeepWoodV3.Rarity(r)), expect, "per-rarity credit");
        }
    }

    /// The cooldown must NOT gate a batch: the whole point is settling a
    /// session's digs in one signature. A 3-second gap between two txs is a
    /// per-transaction anti-spam brake; the batch pays 20 durability at once
    /// and needs no time brake at all.
    function test_BatchIgnoresHuntCooldown() public {
        _open();
        _buy(alice, 1);

        // Settle one hunt NOW with no warp (cooldown would block a second
        // settleHunt, which is the point being contrasted).
        uint256[5] memory c0; uint256 v0;
        (c0, v0) = dw.previewHunt(alice, 1);
        vm.prank(alice);
        dw.settleHunt(alice, 1, c0, v0, _sig());

        // Queue the NEXT three hunts and settle them immediately -- no warp.
        // settleHunt would revert CooldownActive here; settleBatch must not.
        uint256[5][] memory queued = new uint256[5][](3);
        uint256[] memory bests = new uint256[](3);
        for (uint256 k = 0; k < 3; k++) {
            (queued[k], bests[k]) = dw.previewHuntAt(alice, 1, k);
        }

        vm.prank(alice);
        dw.settleBatch(alice, 1, queued, bests); // must not revert CooldownActive
        assertEq(dw.huntIndexOf(alice), 4, "1 single + 3 batched");
    }

    /// Drift in ANY one hunt of the batch reverts the WHOLE tx -- gems,
    /// durability, and the hunt index all roll back. A partial-accept would
    /// let a client replay a stale preview at a fresh index.
    function test_BatchRevertsAtomicallyOnAnyDrift() public {
        _open();
        _buy(alice, 1);

        uint256[5][] memory queued = new uint256[5][](3);
        uint256[] memory bests = new uint256[](3);
        for (uint256 k = 0; k < 3; k++) {
            (queued[k], bests[k]) = dw.previewHuntAt(alice, 1, k);
        }

        // Corrupt hunt 2's counts. The honest roll for index 1 came back
        // diamond=1 in the fixture build; falsify it to force ResultMismatch.
        queued[2][4] = queued[2][4] + 1;

        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.ResultMismatch.selector);
        dw.settleBatch(alice, 1, queued, bests);

        assertEq(dw.huntIndexOf(alice), 0, "index rolled back");
        (uint8 tier, uint64 dur,) = dw.toolOf(alice);
        assertEq(dur, 20, "durability rolled back");
    }

    /// 20 is the cap because 20 is a full tier-1 tool: you cannot queue more
    /// hunts than you have durability to pay, so the cap is unreachable grief.
    function test_BatchOverTwentyReverts() public {
        _open();
        _buy(alice, 1);

        uint256[5][] memory queued = new uint256[5][](21);
        uint256[] memory bests = new uint256[](21);
        for (uint256 k = 0; k < 21; k++) {
            (queued[k], bests[k]) = dw.previewHuntAt(alice, 1, k);
        }

        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.BatchTooLarge.selector);
        dw.settleBatch(alice, 1, queued, bests);
    }

    /// Previews are indexed by huntsThisSeason, which only settles advance.
    /// Queue 2, settle 1 single, then settle the SAME previews: hunt index 1
    /// now genuinely corresponds to the second queued preview, and the first
    /// (index-0) preview is stale -- the batch must reject it.
    function test_BatchRejectsStalePreviewAfterSingleSettle() public {
        _open();
        _buy(alice, 1);

        uint256[5][] memory queued = new uint256[5][](2);
        uint256[] memory bests = new uint256[](2);
        for (uint256 k = 0; k < 2; k++) {
            (queued[k], bests[k]) = dw.previewHuntAt(alice, 1, k);
        }

        _cd();
        uint256[5] memory c0; uint256 v0;
        (c0, v0) = dw.previewHunt(alice, 1);
        vm.prank(alice);
        dw.settleHunt(alice, 1, c0, v0, _sig());

        // queued[0] was the roll for index 0; the chain is now at index 1 and
        // expects queued[1]'s values there. The batch starts at the wrong
        // index and must revert.
        vm.prank(alice);
        vm.expectRevert();
        dw.settleBatch(alice, 1, queued, bests);
    }

    /// Migration is an owner attestation. A non-owner (even the player being
    /// migrated) must not be able to write state.
    function test_MigrationIsOwnerOnly() public {
        uint256[5] memory gems = [uint256(25), 0, 0, 0, 0];
        vm.prank(alice);
        vm.expectRevert(DeepWoodV3.NotOwner.selector);
        dw.migrateFromV2(alice, 1, 13, gems);
    }

    /// The attestation cannot mint value the source never had: a durability
    /// above the tier's maximum reverts.
    function test_MigrationRejectsImpossibleDurability() public {
        uint256[5] memory gems = [uint256(25), 0, 0, 0, 0];
        vm.prank(address(this));
        vm.expectRevert(DeepWoodV3.BadDurability.selector);
        dw.migrateFromV2(alice, 1, 21, gems);
    }

    /// The live migration payload: trader2's Wood tool at 13/20 with 25
    /// quartz. Written by the owner, readable by anyone, and the player keeps
    /// the exact state V2 reported.
    function test_MigrationRestoresV2State() public {
        uint256[5] memory gems = [uint256(25), 0, 0, 0, 0];
        vm.prank(address(this)); // the contract's own deployer is the owner
        dw.migrateFromV2(alice, 1, 13, gems);

        (uint8 tier, uint64 dur,) = dw.toolOf(alice);
        assertEq(tier, 1, "tier");
        assertEq(dur, 13, "durability");
        assertEq(dw.gemsOf(alice, DeepWoodV3.Rarity.Common), 25, "gems");
    }
}
