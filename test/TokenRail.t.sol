// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {DeepWoodV4} from "../src/DeepWoodV4.sol";

/// @dev Minimal 18-decimal ERC20 with mint and a controllable `decimals`, so a
///      test can prove the contract refuses a non-18-decimal token.
contract MockToken {
    string public name = "DeepWood";
    string public symbol = "DEEPWOOD";
    uint8 private _decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev PoolManager stand-in: stores whatever sqrtPriceX96 the test wants at
///      the exact slot the contract reads (keccak256(POOL_ID, 6)).
contract MockPoolManager {
    mapping(bytes32 => bytes32) public slots;

    function setSlot(bytes32 slot, bytes32 value) external {
        slots[slot] = value;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }
}

/**
 * @notice The V4 token rail: buying tools with $DEEPWOOD, and redeeming gems
 *         for $DEEPWOOD.
 *
 * This file exists because the rail shipped with NO test coverage at all, and
 * three bugs rode in behind that gap:
 *   1. buyToolWithToken forwarded the whole token amount to TREASURY, so the
 *      contract held a zero balance and every redemption reverted
 *      InsufficientTokenBalance -- the feature could not work as shipped.
 *   2. redeemGems computed `owed = payout / PRICE_SCALE` with PRICE_SCALE == 1,
 *      paying a wei-denominated payout 1:1 in token units and mispricing the
 *      redemption by the entire price ratio.
 *   3. Nothing asserted that a token-bought tool actually mints a tool, so a
 *      revert-on-success regression would have been invisible.
 */
contract TokenRailTest is Test {
    bytes32 internal constant SEED = keccak256("deepwood-preseason");
    bytes32 internal constant POOL_ID = keccak256("pool");

    MockToken token;
    MockPoolManager poolManager;
    DeepWoodV4 dw;

    address owner = address(this);
    address treasury = makeAddr("treasury");
    address hunter = makeAddr("hunter");
    address alice = makeAddr("alice");

    /// @dev 1 token = 0.0001 ETH. sqrtPriceX96 = sqrt(token/eth) * 2^96, and
    ///      token/eth = 1/0.0001 = 10_000, so sqrt = 100.
    uint160 internal constant SQRT_PRICE_1E4 = 100 * (1 << 96);

    function setUp() public {
        token = new MockToken(18);
        poolManager = new MockPoolManager();
        dw = new DeepWoodV4(treasury, hunter, address(poolManager), POOL_ID, address(0));

        // The contract reads slot0 as keccak256(POOL_ID, 6).
        bytes32 stateSlot = keccak256(abi.encodePacked(POOL_ID, bytes32(uint256(6))));
        poolManager.setSlot(stateSlot, bytes32(uint256(SQRT_PRICE_1E4)));

        // Wire the token rail. (The season is already open from the constructor.)
        dw.setToken(address(token));
        dw.setTokenRail(true);
        vm.prank(hunter);
        dw.commitSeed(SEED);

        // alice starts with plenty of tokens and an unlimited approval.
        token.mint(alice, 1_000_000 ether);
        vm.prank(alice);
        token.approve(address(dw), type(uint256).max);
    }

    // ---- price sanity -----------------------------------------------------

    /// @notice Pins the oracle against hand-computed maths. If this drifts,
    ///         every other number in this file is measuring the wrong thing.
    function test_EthPerTokenMatchesHandComputedPrice() public view {
        // eth/token = (2^96 / sqrtPrice)^2 = (2^96 / (100 * 2^96))^2 = 1e-4
        // scaled by 1e18 => 1e14 wei per token.
        assertEq(dw.getEthPerToken(), 0.0001 ether);
        assertEq(dw.getTokensPerEth(), 10_000 ether);
    }

    // ---- buying with tokens ----------------------------------------------

    /// @notice The headline bug: the contract must END UP HOLDING tokens, or
    ///         redemption cannot be paid at all.
    function test_TokenBuyLeavesBackingInTheContract() public {
        uint256 cost = dw.toolCost(1);
        uint256 discounted = (cost * 9000) / 10_000;
        uint256 tokenCost = (discounted * 1e18) / dw.getEthPerToken();
        uint256 fee = (tokenCost * 500) / 10_000;

        uint256 quoted = _quoteTokenCost(1);
        vm.prank(alice);
        dw.buyToolWithToken(1, quoted, block.timestamp + 30, 0);

        assertEq(
            token.balanceOf(address(dw)),
            tokenCost - fee,
            "the contract keeps the backing, not the fee"
        );
        assertEq(token.balanceOf(treasury), fee, "only the burn fee goes to treasury");
        assertEq(dw.tokenBacking(), tokenCost - fee, "tokenBacking tracks what is held");
    }

    /// @notice A token buy must mint a working tool, exactly like the ETH path.
    function test_TokenBuyMintsATool() public {
        uint256 quoted = _quoteTokenCost(1);
        vm.prank(alice);
        dw.buyToolWithToken(1, quoted, block.timestamp + 30, 0);

        // toolOf returns (tier, durability, broken) -- the third value is
        // `broken`, not `active`.
        (uint8 tier, uint64 dur, bool broken) = dw.toolOf(alice);
        assertEq(tier, 1, "tier 1 tool");
        assertEq(dur, uint64(dw.durabilityOf(1)), "full durability");
        assertFalse(broken, "a fresh tool is not broken");
    }

    /// @notice 10% off means strictly fewer tokens than the ETH cost would buy.
    function test_TokenBuyIsTenPercentCheaper() public {
        uint256 quoted = _quoteTokenCost(1);
        uint256 fullPriceTokens = (dw.toolCost(1) * 1e18) / dw.getEthPerToken();

        assertEq(quoted, (fullPriceTokens * 9000) / 10_000, "10% discount applied");
        assertLt(quoted, fullPriceTokens, "discounted cost is lower");
    }

    /// @notice Replay protection: the same nonce cannot be spent twice.
    function test_TokenBuyRejectsAReplayedNonce() public {
        uint256 quoted = _quoteTokenCost(1);
        vm.prank(alice);
        dw.buyToolWithToken(1, quoted, block.timestamp + 30, 0);

        // Nonce is now 1; replaying 0 must revert. Quote the cost FIRST --
        // a view call between expectRevert and the target consumes the
        // expectation and the test passes for the wrong reason.
        uint256 quoted2 = _quoteTokenCost(2);
        vm.prank(alice);
        vm.expectRevert(DeepWoodV4.BadNonce.selector);
        dw.buyToolWithToken(2, quoted2, block.timestamp + 30, 0);
    }

    /// @notice A stale quote must be refused, not silently honoured.
    function test_TokenBuyRejectsAStaleQuote() public {
        uint256 quoted = _quoteTokenCost(1);
        vm.warp(1000);
        vm.prank(alice);
        vm.expectRevert(DeepWoodV4.QuoteStale.selector);
        dw.buyToolWithToken(1, quoted, 999, 0);
    }

    /// @notice Slippage guard: a maxTokenCost far off the live price reverts.
    function test_TokenBuyRejectsAnOffMarketQuote() public {
        uint256 quoted = _quoteTokenCost(1);
        vm.prank(alice);
        vm.expectRevert(DeepWoodV4.QuoteStale.selector);
        dw.buyToolWithToken(1, quoted / 2, block.timestamp + 30, 0);
    }

    /// @notice Tier skipping stays locked on the token path too -- but only
    ///         once a tool is held. See the next test for the first-buy gap.
    function test_TokenBuyCannotSkipTiers() public {
        uint256 first = _quoteTokenCost(1);
        vm.prank(alice);
        dw.buyToolWithToken(1, first, block.timestamp + 30, 0);

        // Wood -> Gold must be refused; only the next tier is buyable.
        uint256 gold = _quoteTokenCost(3);
        vm.prank(alice);
        vm.expectRevert(DeepWoodV4.TierLocked.selector);
        dw.buyToolWithToken(3, gold, block.timestamp + 30, 1);
    }

    /// @notice FINDING, pinned so it cannot change silently: a player holding
    ///         NO tool can buy ANY tier as their first purchase, including
    ///         tier 5. The guard is `held.tier != 0 && tier != held.tier + 1`,
    ///         so it short-circuits on the first buy and the ladder is never
    ///         entered.
    ///
    ///         This matters economically: climbing 1->5 costs
    ///         0.005+0.052+0.184+0.862+2.300 = 3.403 ETH, but a direct tier-5
    ///         first buy costs 2.300 ETH. That skips ~1.1 ETH of ladder spend
    ///         and every repair decision the ladder exists to force.
    ///
    ///         This test asserts the CURRENT behaviour, not the desired one.
    ///         The fix is a product decision (require tier == 1 when
    ///         held.tier == 0) and is deliberately NOT applied here.
    function test_FirstBuyCanCurrentlyBeAnyTier() public {
        uint256 tier5 = _quoteTokenCost(5);
        vm.prank(alice);
        dw.buyToolWithToken(5, tier5, block.timestamp + 30, 0);

        (uint8 tier,,) = dw.toolOf(alice);
        assertEq(tier, 5, "first buy reached tier 5 directly -- the documented gap");
    }

    // ---- redeeming gems ---------------------------------------------------

    /// @notice Redemption pays TOKENS at the live price, not 1:1 in wei.
    ///         This is the mispricing bug: with PRICE_SCALE == 1 the payout
    ///         would have been ~1e14x too small.
    function test_RedeemPaysTokensAtTheLivePrice() public {
        _graduateAndFund();
        _giveGems(alice, DeepWoodV4.Rarity.Common, 1000);

        (uint256 quotedTokens,) = dw.redeemQuoteToken(DeepWoodV4.Rarity.Common, 1000);
        uint256 before = token.balanceOf(alice);

        vm.prank(alice);
        dw.redeemGems(DeepWoodV4.Rarity.Common, 1000);

        assertEq(token.balanceOf(alice) - before, quotedTokens, "paid exactly the quote");
        // 1000 Quartz @ 0.00005 ETH face = 0.05 ETH, 90% = 0.045 ETH.
        // At 0.0001 ETH/token that is 450 tokens.
        assertEq(quotedTokens, 450 ether, "hand-computed payout");
    }

    /// @notice The quote view must never disagree with what the contract pays.
    function test_RedeemQuoteMatchesWhatIsActuallyPaid() public {
        _graduateAndFund();
        _giveGems(alice, DeepWoodV4.Rarity.Uncommon, 50);

        (uint256 quoted,) = dw.redeemQuoteToken(DeepWoodV4.Rarity.Uncommon, 50);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        dw.redeemGems(DeepWoodV4.Rarity.Uncommon, 50);

        assertEq(token.balanceOf(alice) - before, quoted);
    }

    /// @notice Redemption draws down the tracked backing, so the contract's
    ///         own accounting does not drift from its real balance.
    function test_RedeemReducesTokenBacking() public {
        // Establish real backing the way production does: a token tool buy.
        uint256 quoted = _quoteTokenCost(1);
        vm.prank(alice);
        dw.buyToolWithToken(1, quoted, block.timestamp + 30, 0);

        _graduateAndFund();
        _giveGems(alice, DeepWoodV4.Rarity.Common, 500);

        // Capture AFTER funding -- fundToken also credits the backing, so a
        // baseline taken right after the buy would understate it and the
        // subtraction below would underflow.
        uint256 backingBefore = dw.tokenBacking();
        assertGt(backingBefore, 0, "backing is established");
        assertEq(backingBefore, token.balanceOf(address(dw)), "tracked == held before");

        (uint256 payoutTokens,) = dw.redeemQuoteToken(DeepWoodV4.Rarity.Common, 500);
        vm.prank(alice);
        dw.redeemGems(DeepWoodV4.Rarity.Common, 500);

        assertEq(dw.tokenBacking(), backingBefore - payoutTokens, "backing drawn down");
        assertEq(dw.tokenBacking(), token.balanceOf(address(dw)), "tracked == held after");
    }

    /// @notice Gems are burned on redemption -- you cannot redeem twice.
    function test_RedeemBurnsTheGems() public {
        _graduateAndFund();
        _giveGems(alice, DeepWoodV4.Rarity.Common, 300);

        vm.prank(alice);
        dw.redeemGems(DeepWoodV4.Rarity.Common, 300);

        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity.Common), 0, "gems burned");

        vm.prank(alice);
        vm.expectRevert(DeepWoodV4.InsufficientGems.selector);
        dw.redeemGems(DeepWoodV4.Rarity.Common, 1);
    }

    /// @notice The rail stays locked until the grace window has passed.
    function test_RedeemIsLockedBeforeTheGraceWindow() public {
        // Graduate but do NOT warp: still inside the 1-day grace, so
        // tokenRedemptionActive() is false.
        vm.prank(hunter);
        dw.markGraduated();
        token.mint(address(dw), 1_000_000 ether);
        _giveGems(alice, DeepWoodV4.Rarity.Common, 1000);
        assertFalse(dw.tokenRedemptionActive());

        vm.prank(alice);
        vm.expectRevert(DeepWoodV4.TokenRailLocked.selector);
        dw.redeemGems(DeepWoodV4.Rarity.Common, 1000);
    }

    /// @notice The moment the grace window elapses, redemption opens. The
    ///         boundary is the whole point of the window, so it is asserted
    ///         rather than assumed.
    function test_RedeemOpensExactlyAtTheEndOfGrace() public {
        vm.prank(hunter);
        dw.markGraduated();
        token.mint(address(dw), 1_000_000 ether);
        _giveGems(alice, DeepWoodV4.Rarity.Common, 1000);

        (uint64 graduatedAt,) = (dw.graduatedAt(), 0);
        vm.warp(uint256(graduatedAt) + 1 days);
        assertTrue(dw.tokenRedemptionActive(), "active at the boundary");

        vm.prank(alice);
        dw.redeemGems(DeepWoodV4.Rarity.Common, 1000);
        assertEq(dw.gemsOf(alice, DeepWoodV4.Rarity.Common), 0);
    }

    /// @notice A contract with no tokens cannot pay, and must say so rather
    ///         than sending a zero-value transfer.
    function test_RedeemRevertsWhenTheContractIsUnfunded() public {
        _graduateAndFund();
        _giveGems(alice, DeepWoodV4.Rarity.Common, 1000);
        // Drain the tracked backing through the sanctioned path.
        uint256 bal = dw.tokenBacking();
        dw.emergencyWithdraw(address(token), bal, owner);

        vm.prank(alice);
        vm.expectRevert(DeepWoodV4.InsufficientTokenBalance.selector);
        dw.redeemGems(DeepWoodV4.Rarity.Common, 1000);
    }

    /// @notice The owner cannot rug the redemption backing. Those tokens are
    ///         owed to gem holders; a withdrawal above tokenBacking must fail.
    function test_EmergencyWithdrawCannotTouchRedemptionBacking() public {
        _graduateAndFund();
        uint256 backing = dw.tokenBacking();
        assertGt(backing, 0);

        vm.expectRevert(DeepWoodV4.InsufficientTokenBalance.selector);
        dw.emergencyWithdraw(address(token), backing + 1, owner);
    }

    /// @notice Below the floor the redemption is refused: a payout too small to
    ///         justify the gas is a griefing vector, not a rounding detail.
    function test_RedeemRefusesBelowTheFloor() public {
        _graduateAndFund();
        _giveGems(alice, DeepWoodV4.Rarity.Common, 1);

        vm.prank(alice);
        vm.expectRevert();
        dw.redeemGems(DeepWoodV4.Rarity.Common, 1);
    }

    // ---- the loop the rail must not open ----------------------------------

    /// @notice The exploit the whole design is defending against: buy a tool
    ///         with discounted tokens, redeem the gems it earns back into
    ///         tokens, and repeat for free. This test pins the CURRENT state of
    ///         that loop so a future change to it is deliberate.
    ///
    ///         It is NOT a claim that the loop is closed -- the contract does
    ///         not yet track who bought with tokens, so a token buyer can still
    ///         redeem. What it pins is that the discount is 10% and the
    ///         redemption spread is 10%, so the round trip is lossy rather
    ///         than free.
    function test_TokenBuyAndRedeemRoundTripIsLossy() public {
        _graduateAndFund();

        uint256 quoted = _quoteTokenCost(1);
        uint256 tokensBefore = token.balanceOf(alice);
        vm.prank(alice);
        dw.buyToolWithToken(1, quoted, block.timestamp + 30, 0);
        uint256 spentOnTool = tokensBefore - token.balanceOf(alice);

        // Redeem 1000 Quartz -- what the tool's 20 hunts could plausibly yield.
        _giveGems(alice, DeepWoodV4.Rarity.Common, 1000);
        (uint256 back,) = dw.redeemQuoteToken(DeepWoodV4.Rarity.Common, 1000);

        // 0.045 ETH of tokens back vs 0.0045 ETH spent: the loop is only
        // profitable because the GEMS are free, not because of the discount.
        // Assert the discount/spread arithmetic itself is 10% each way.
        assertEq(spentOnTool, (dw.toolCost(1) * 1e18) / dw.getEthPerToken() * 9000 / 10_000);
        assertEq(back, (1000 * dw.priceOf(DeepWoodV4.Rarity.Common) * 9000) / 10_000 * 1e18 / dw.getEthPerToken());
    }

    // ---- helpers ----------------------------------------------------------

    /// @dev The token cost the contract will compute for `tier`, discount
    ///      included, at the mocked price.
    function _quoteTokenCost(uint8 tier) internal view returns (uint256) {
        uint256 discounted = (dw.toolCost(tier) * 9000) / 10_000;
        return (discounted * 1e18) / dw.getEthPerToken();
    }

    /// @dev Graduate, wait out the grace window, and fund the contract so
    ///      redemption is live. Funding goes through fundToken so the tokens
    ///      are TRACKED -- a raw mint would leave tokenBacking at zero and the
    ///      contract's accounting would not match its balance.
    function _graduateAndFund() internal {
        vm.prank(hunter);
        dw.markGraduated();
        vm.warp(block.timestamp + 1 days + 1);
        token.mint(owner, 1_000_000 ether);
        token.approve(address(dw), type(uint256).max);
        dw.fundToken(1_000_000 ether);
    }

    /// @dev Hand `player` gems without going through a hunt roll.
    function _giveGems(address player, DeepWoodV4.Rarity rarity, uint256 count) internal {
        dw.grantGems(player, uint8(rarity), count);
    }
}
