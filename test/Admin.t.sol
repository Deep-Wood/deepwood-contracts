// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeepWood, IERC20} from "../src/DeepWood.sol";
import {DeepWoodToken} from "../src/DeepWoodToken.sol";

/**
 * @notice Tests for the owner/admin surface and the token rail.
 *
 * The theme throughout: an owner with full control should still not be able to
 * brick the game or silently reopen a closed exploit. Every guard in setConfig
 * is exercised here, because a guard nobody tests is a guard that does not
 * exist.
 */
contract AdminTest is Test {
    bytes32 internal constant SEED = keccak256("deepwood-season-1-seed");
    DeepWood dw;
    DeepWoodToken token;

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address hunter = makeAddr("hunter");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address rando = makeAddr("rando");

    function setUp() public {
        dw = new DeepWood(treasury, hunter);
        token = new DeepWoodToken(address(this), 1_000_000 ether);
    }

    // ---- owner basics -----------------------------------------------------

    function test_OwnerIsDeployer() public view {
        assertEq(dw.owner(), owner, "deployer is the initial owner");
    }

    function test_NonOwnerCannotSetConfig() public {
        vm.prank(rando);
        vm.expectRevert(DeepWood.NotOwner.selector);
        dw.setConfig(1, 1 days, 1, 1, 1, 1, 1);
    }

    function test_NonOwnerCannotPause() public {
        vm.prank(rando);
        vm.expectRevert(DeepWood.NotOwner.selector);
        dw.setPaused(true);
    }

    function test_NonOwnerCannotSetToken() public {
        vm.prank(rando);
        vm.expectRevert(DeepWood.NotOwner.selector);
        dw.setToken(address(token));
    }

    function test_OwnershipTransfers() public {
        dw.transferOwnership(bob);
        assertEq(dw.owner(), bob);
        vm.prank(rando);
        vm.expectRevert(DeepWood.NotOwner.selector);
        dw.setPaused(true);
        vm.prank(bob);
        dw.setPaused(true);
        assertTrue(dw.paused());
    }

    function test_CannotTransferOwnershipToZero() public {
        vm.expectRevert(DeepWood.NotOwner.selector);
        dw.transferOwnership(address(0));
    }

    // ---- config: the guards ----------------------------------------------

    function test_ConfigSeededWithOriginalValues() public view {
        (uint256 burn, uint64 season, uint64 cd, uint256 splay, uint64 grace, uint8 base, uint8 max) = dw.getConfig();
        assertEq(burn, 500, "burn fee unchanged from the old constant");
        assertEq(season, 14 days, "season length unchanged");
        assertEq(cd, 3, "cooldown unchanged");
        assertEq(splay, 0.005 ether, "splay floor unchanged");
        assertEq(grace, 1 days, "graduation grace unchanged");
        assertEq(base, 1, "base slots unchanged");
        assertEq(max, 4, "max slots unchanged");
    }

    function test_RetuneBurnFee() public {
        dw.setConfig(1000, 14 days, 3, 0.005 ether, 1 days, 1, 4);
        (uint256 burn,,,,,, ) = dw.getConfig();
        assertEq(burn, 1000, "burn fee is now 10%");
    }

    function test_RejectBurnFeeAbove100Percent() public {
        vm.expectRevert(DeepWood.BadConfig.selector);
        dw.setConfig(10_001, 14 days, 3, 0.005 ether, 1 days, 1, 4);
    }

    function test_RejectZeroSeasonLength() public {
        vm.expectRevert(DeepWood.BadConfig.selector);
        dw.setConfig(500, 0, 3, 0.005 ether, 1 days, 1, 4);
    }

    function test_RejectAbsurdSeasonLength() public {
        vm.expectRevert(DeepWood.BadConfig.selector);
        dw.setConfig(500, 366 days, 3, 0.005 ether, 1 days, 1, 4);
    }

    function test_RejectZeroSplayFloor() public {
        // The single most important guard: minSplay == 0 re-opens the
        // splay-floor exploit that lets one lucky hunt top the ROI board.
        vm.expectRevert(DeepWood.BadConfig.selector);
        dw.setConfig(500, 14 days, 3, 0, 1 days, 1, 4);
    }

    function test_RejectMaxSlotsBelowBase() public {
        vm.expectRevert(DeepWood.BadConfig.selector);
        dw.setConfig(500, 14 days, 3, 0.005 ether, 1 days, 4, 2);
    }

    function test_RejectZeroBaseSlots() public {
        vm.expectRevert(DeepWood.BadConfig.selector);
        dw.setConfig(500, 14 days, 3, 0.005 ether, 1 days, 0, 4);
    }

    function test_RejectCooldownOverAnHour() public {
        vm.expectRevert(DeepWood.BadConfig.selector);
        dw.setConfig(500, 14 days, 2 hours, 0.005 ether, 1 days, 1, 4);
    }

    function test_RejectSlotsOverHardCap() public {
        vm.expectRevert(DeepWood.BadConfig.selector);
        dw.setConfig(500, 14 days, 3, 0.005 ether, 1 days, 1, 200);
    }

    function test_ConfigIsAllOrNothing() public {
        // A rejected config must leave the old one completely intact.
        (, uint64 seasonBefore, , , , , ) = dw.getConfig();
        vm.expectRevert(DeepWood.BadConfig.selector);
        dw.setConfig(999, 21 days, 9, 0, 5 days, 2, 8); // minSplay=0 is illegal
        (uint256 burn, uint64 season, uint64 cd, uint256 splay, uint64 grace, uint8 base, uint8 max) = dw.getConfig();
        assertEq(burn, 500, "burn untouched");
        assertEq(season, seasonBefore, "season untouched");
        assertEq(cd, 3, "cooldown untouched");
        assertEq(splay, 0.005 ether, "splay untouched");
        assertEq(grace, 1 days, "grace untouched");
        assertEq(base, 1, "base untouched");
        assertEq(max, 4, "max untouched");
    }

    function test_RetunedBurnFeeActuallyCharges() public {
        _commit();
        dw.setConfig(1000, 14 days, 3, 0.005 ether, 1 days, 1, 4);
        vm.deal(alice, 1000 ether);
        uint256 price = dw.priceOf(DeepWood.Rarity.Common);
        // Skill 1 costs 500 gems, so she needs more than that.
        vm.prank(alice);
        dw.buyGems{value: price * 1000}(DeepWood.Rarity.Common, 1000);
        assertEq(dw.gemsOf(alice, DeepWood.Rarity.Common), 1000);

        // Upgrade spends Common gems; 10% should now go to the treasury.
        uint256 before = dw.treasuryGems();
        uint256 held = dw.gemsOf(alice, DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.upgradeSkill(1);
        uint256 spent = held - dw.gemsOf(alice, DeepWood.Rarity.Common);
        assertEq(spent, 500, "skill 1 costs exactly 500 gems");
        assertEq(dw.treasuryGems() - before, (spent * 1000) / dw.BPS_DENOMINATOR(), "10% fee, not 5%");
    }

    function test_RetunedCooldownActuallyApplies() public {
        _ready(alice);
        _commit();
        dw.setConfig(500, 14 days, 60, 0.005 ether, 1 days, 1, 4);
        uint256 cost = dw.huntCostWei(1);
        // lastHuntAt starts at 0, so the first hunt is gated until the
        // cooldown has elapsed since epoch (as on any real chain).
        _cd();

        (uint256[5] memory c0, uint256 v0) = dw.previewHunt(alice, 1);
        vm.prank(alice);
        dw.settleHunt(alice, 1, c0, v0, _sig());

        // 30s is inside the new 60s cooldown.
        vm.warp(block.timestamp + 30);
        vm.expectRevert(DeepWood.CooldownActive.selector);
        vm.prank(alice);
        dw.settleHunt(alice, 1, c0, v0, _sig());

        vm.warp(block.timestamp + 31);
        (uint256[5] memory c1, uint256 v1) = dw.previewHunt(alice, 1);
        vm.prank(alice);
        dw.settleHunt(alice, 1, c1, v1, _sig());
        (,,,,, uint64 hunts) = dw.playerStats(alice);
        assertEq(hunts, 2, "second hunt landed after the cooldown");
    }

    // ---- pause ------------------------------------------------------------

    function test_PauseBlocksPlayButTreasuryCanAlwaysExit() public {
        // The treasury accrues burn fees as gem units, so give it gems first.
        vm.deal(treasury, 1000 ether);
        vm.prank(treasury);
        dw.buyGems{value: 1 ether}(DeepWood.Rarity.Common, 1000);
        vm.prank(treasury);
        dw.upgradeSkill(1);
        assertGt(dw.treasuryGems(), 0, "treasury accrued a burn fee");

        dw.setPaused(true);
        assertTrue(dw.paused());

        vm.deal(alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(DeepWood.Paused.selector);
        dw.buyGems{value: 0.001 ether}(DeepWood.Rarity.Common, 1);

        // A pause must never trap the treasury's money.
        uint256 owed = dw.treasuryGems();
        vm.prank(treasury);
        dw.treasuryRedeem(owed);
        assertEq(dw.treasuryGems(), 0, "treasury exited while paused");
    }

function test_UnpauseRestoresPlay() public {
        dw.setPaused(true);
        dw.setPaused(false);
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        dw.buyGems{value: 0.001 ether}(DeepWood.Rarity.Common, 1);
        assertEq(dw.gemsOf(alice, DeepWood.Rarity.Common), 1);
    }

    // ---- token wiring -----------------------------------------------------

    function test_CannotEnableRailWithoutToken() public {
        vm.expectRevert(DeepWood.NoToken.selector);
        dw.setTokenRail(true);
    }

    function test_CannotFundWithoutToken() public {
        vm.expectRevert(DeepWood.NoToken.selector);
        dw.fundToken(1 ether);
    }

    function test_ClearingTokenAlsoDisablesRail() public {
        dw.setToken(address(token));
        dw.setTokenRail(true);
        assertTrue(dw.tokenRailEnabled());
        dw.setToken(address(0));
        assertFalse(dw.tokenRailEnabled(), "unwiring the token must kill the rail");
        assertEq(dw.token(), address(0));
    }

    function test_FundTokenMovesBalance() public {
        token.mint(address(this), 200 ether);
        dw.setToken(address(token));
        token.approve(address(dw), 100 ether);
        dw.fundToken(100 ether);
        assertEq(token.balanceOf(address(dw)), 100 ether, "contract holds the funding");
        assertEq(token.balanceOf(address(this)), 100 ether, "owner paid for it");
    }

    // ---- token redemption -------------------------------------------------

    function test_RedeemsInEthBeforeGraduation() public {
        vm.deal(alice, 10 ether);
        uint256 price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: price * 10}(DeepWood.Rarity.Common, 10);

        uint256 before = alice.balance;
        vm.prank(alice);
        dw.redeemGems(DeepWood.Rarity.Common, 10);
        assertEq(alice.balance - before, price * 10, "paid in ETH at face value");
    }

    function test_RedeemsInTokenOnceRailIsLive() public {
        // Give alice gems by buying them, then graduate + wire + enable.
        vm.deal(alice, 1000 ether);
        uint256 price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: price * 10}(DeepWood.Rarity.Common, 10);
        uint256 gems = dw.gemsOf(alice, DeepWood.Rarity.Common);

        token.mint(address(this), 1_000_000 ether);
        dw.setToken(address(token));
        dw.setTokenRail(true);
        token.approve(address(dw), 1_000_000 ether);
        dw.fundToken(1_000_000 ether);

        vm.prank(hunter);
        dw.markGraduated();
        (, , , , uint64 grace, , ) = dw.getConfig();
        vm.warp(block.timestamp + grace + 1);
        assertTrue(dw.tokenRedemptionActive());

        uint256 tokenBefore = token.balanceOf(alice);
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        dw.redeemGems(DeepWood.Rarity.Common, gems);

        assertEq(token.balanceOf(alice) - tokenBefore, price * gems, "paid in token at face value");
        assertEq(alice.balance, ethBefore, "no ETH left the contract on the token rail");
        assertEq(dw.gemsOf(alice, DeepWood.Rarity.Common), 0, "gems were debited exactly once");
    }

function test_TokenRedemptionRefusesIfContractIsUnderfunded() public {
        vm.deal(alice, 1000 ether);
        uint256 price = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(alice);
        dw.buyGems{value: price * 10}(DeepWood.Rarity.Common, 10);

        uint256 claim = price * 10;
        token.mint(address(this), claim - 1); // one wei short of covering it
        dw.setToken(address(token));
        dw.setTokenRail(true);
        token.approve(address(dw), claim - 1);
        dw.fundToken(claim - 1);

        vm.prank(hunter);
        dw.markGraduated();
        (, , , , uint64 grace, , ) = dw.getConfig();
        vm.warp(block.timestamp + grace + 1);

        vm.prank(alice);
        vm.expectRevert(DeepWood.InsufficientTokenBalance.selector);
        dw.redeemGems(DeepWood.Rarity.Common, 10);

        // The failed redemption must not have eaten the gems.
        assertEq(dw.gemsOf(alice, DeepWood.Rarity.Common), 10, "gems survive a failed payout");
    }

    // ---- token contract itself -------------------------------------------

    function test_TokenRespectsCap() public {
        DeepWoodToken capped = new DeepWoodToken(address(this), 100 ether);
        capped.mint(alice, 60 ether);
        vm.expectRevert(DeepWoodToken.CapExceeded.selector);
        capped.mint(bob, 41 ether);
    }

    function test_TokenMintingClosesForever() public {
        token.mint(alice, 10 ether);
        token.seal();
        assertTrue(token.mintClosed(), "minting is now closed");
        vm.expectRevert(DeepWoodToken.MintClosed_.selector);
        token.mint(alice, 1 ether);
        assertEq(token.totalSupply(), 10 ether, "supply did not grow after closing");
    }

    function test_TokenNonOwnerCannotMint() public {
        vm.prank(rando);
        vm.expectRevert(DeepWoodToken.NotOwner.selector);
        token.mint(rando, 1 ether);
    }

    function test_TokenTransfersAndAllowances() public {
        token.mint(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 40 ether);
        vm.prank(bob);
        token.transferFrom(alice, bob, 25 ether);
        assertEq(token.balanceOf(alice), 75 ether);
        assertEq(token.balanceOf(bob), 25 ether);
        assertEq(token.allowance(alice, bob), 15 ether);
    }

    function test_TokenInsufficientBalance() public {
        vm.prank(rando);
        vm.expectRevert(DeepWoodToken.InsufficientBalance.selector);
        token.transfer(alice, 1 ether);
    }

    function test_TokenInsufficientAllowance() public {
        token.mint(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(DeepWoodToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 2 ether);
    }

    function test_TokenIs18Decimals() public view {
        assertEq(token.decimals(), 18, "game requires 18-decimal tokens");
    }

    // ---- helpers ----------------------------------------------------------

    function _sig() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(7)), bytes32(uint256(9)));
    }

    function _g(uint256 c, uint256 u, uint256 r, uint256 e, uint256 l) internal pure returns (uint256[5] memory) {
        return [c, u, r, e, l];
    }

    function _commit() internal {
        vm.prank(hunter);
        dw.commitSeason(bytes32(uint256(0xC0FFEE)));
        vm.prank(hunter);
        dw.commitSeed(SEED);
    }

    function _cd() internal {
        (, , uint64 cd, , , , ) = dw.getConfig();
        vm.warp(block.timestamp + cd + 1);
    }

    /// @notice A player with a claimed tier-1 tool and a committed season, so
    ///         settleHunt is legal.
    function _ready(address a) internal {
        vm.deal(a, 1000 ether);
        uint256 p = dw.priceOf(DeepWood.Rarity.Common);
        vm.prank(a);
        dw.buyGems{value: p}(DeepWood.Rarity.Common, 1);
        vm.prank(a);
        dw.claimTool(1);
    }
}

// --- season open/close ----------------------------------------------------
//
// The rule: a season that has been finalized away comes back CLOSED, and the
// owner opens it deliberately. Without this, a rollover silently starts
// accepting hunts against a seed nobody has had a chance to look at.
contract SeasonOpenGateTest is Test {
    DeepWood dw;
    address owner = address(this);
    address hunter = address(0xBEEF);
    address alice = address(0xA11CE);

    function setUp() public {
        dw = new DeepWood(address(0xCAFE), hunter);
        vm.startPrank(hunter);
        dw.commitSeason(bytes32(uint256(0xC0FFEE)));
        dw.commitSeed(keccak256("season-open-gate"));
        vm.stopPrank();
        vm.prank(alice);
        dw.claimTool(1);
    }

    function _seasonLength() internal view returns (uint64) {
        (, uint64 len, , , , , ) = dw.getConfig(); // seasonLength is word 1; word 2 is huntCooldown
        return len;
    }

    function _roll() internal returns (uint256[5] memory c, uint256 best) {
        (c, best) = dw.previewHunt(alice, 1);
    }

    /// Foundry starts the block at timestamp 1 and the cooldown is 3s, so an
    /// un-warped first settle always reverts CooldownActive. Warp once here
    /// rather than in each test.
    function _pastCooldown() internal {
        vm.warp(block.timestamp + 100);
    }

    function test_SeasonOneIsOpenSoTheGameWorksImmediately() public {
        assertTrue(dw.seasonOpen(), "a fresh deployment must accept hunts");
    }

    function test_CloseStopsSettlementImmediately() public {
        _pastCooldown();
        vm.prank(owner);
        dw.closeSeason();
        assertFalse(dw.seasonOpen());
        (uint256[5] memory c, uint256 best) = _roll();
        vm.prank(alice);
        vm.expectRevert(DeepWood.SeasonNotOpen.selector);
        dw.settleHunt(alice, 1, c, best, "");
    }

    function test_OpenRestoresIt() public {
        _pastCooldown();
        vm.startPrank(owner);
        dw.closeSeason();
        dw.openSeason();
        vm.stopPrank();
        assertTrue(dw.seasonOpen());
        (uint256[5] memory c, uint256 best) = _roll();
        vm.prank(alice);
        dw.settleHunt(alice, 1, c, best, "");
        assertEq(dw.huntIndexOf(alice), 1, "settlement works again");
    }

    function test_OpenRequiresACommittedSeed() public {
        vm.warp(block.timestamp + _seasonLength() + 1);
        dw.finalizeSeason(); // season 2 starts closed with NO seed
        assertFalse(dw.seasonOpen(), "the next season must come up closed");
        vm.prank(owner);
        vm.expectRevert(DeepWood.SeedNotCommitted.selector);
        dw.openSeason();
    }

    function test_NextSeasonIsClosedUntilOpened() public {
        _pastCooldown();
        vm.warp(block.timestamp + _seasonLength() + 1);
        dw.finalizeSeason();
        assertEq(dw.seasonSeed(), bytes32(0), "a new season has no seed yet");
        assertFalse(dw.seasonOpen(), "closed, not live");

        vm.startPrank(hunter);
        dw.commitSeason(bytes32(uint256(0xBEEF)));
        dw.commitSeed(keccak256("season-2"));
        vm.stopPrank();
        vm.prank(owner);
        dw.openSeason();
        assertTrue(dw.seasonOpen());

        // A closed-then-opened season settles its own player's hunt at index 0.
        (uint256[5] memory c, uint256 best) = _roll();
        vm.prank(alice);
        dw.settleHunt(alice, 1, c, best, "");
        assertEq(dw.huntIndexOf(alice), 1);
    }

    function test_OnlyTheOwnerCanOpenOrClose() public {
        vm.prank(alice);
        vm.expectRevert();
        dw.closeSeason();
        vm.prank(hunter);
        vm.expectRevert();
        dw.openSeason();
    }

    function test_OpeningTwiceReverts() public {
        vm.prank(owner);
        vm.expectRevert(DeepWood.AlreadyCommitted.selector);
        dw.openSeason();
    }
}
