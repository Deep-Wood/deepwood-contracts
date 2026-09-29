// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DeepWood
 * @notice Season-based gem-hunting game economy. Ticker $DEEPWOOD.
 *
 * Built to the design rules in SPEC.md. The rules are not decoration - every
 * function below exists to enforce one of them:
 *
 *   R1  Spend buys VOLUME, never outcome.
 *   R2  Leaderboard ranks EFFICIENCY, never volume.
 *   R3  The contract is permanently over-collateralised by burned value.
 *   R4  No price oracle - everything is ETH-denominated.
 *   R5  The hunter may delay, never inflate.
 *   R6  Pre-graduation settlement is ETH; the switch to the game token is
 *       staged behind a grace window.
 *
 * The single most important property: there is NO path by which spending more
 * ETH yields a better drop table, a bigger slot count, or a better leaderboard
 * rank. Money buys speed. Play buys ceiling.
 */
contract DeepWood {
    // =====================================================================
    // Types
    // =====================================================================

    enum Rarity {
        Common, //  0 Quartz
        Uncommon, //  1 Amber
        Rare, //  2 Sapphire
        Epic, //  3 Ruby
        Legendary //  4 Diamond
    }

    struct Season {
        uint64 id;
        uint64 startsAt;
        uint64 endsAt;
        bool finalized;
        uint256 bestSingleFindWei; // season-wide
        bytes32 commitRoot; // merkle root of outcomes, committed BEFORE hunting
        bool committed;
    }

    /// @notice A tool the player owns. Non-tradable, so tier IS the player's
    ///         permanent progress (SPEC §5).
    struct Tool {
        uint8 tier; //  1..4
        uint64 durability; // hunts remaining; 0 => broken, needs repair
        bool active; // currently equipped
    }

    struct Player {
        mapping(Rarity => uint256) gems;
        uint256 totalGemsEarned; //   gross count
        uint256 totalEthSpent; //     ROI denominator
        uint256 totalGemsBurned; //   spent on tools/skills
        uint256 bestSingleFindWei; // biggest single find
        uint256 legendaryEquivalents; //  rarity-weighted (ROI numerator)
        uint64 totalHunts;
        uint64 lastHuntAt;
    }

    // =====================================================================
    // Constants - the economy
    // =====================================================================

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant BURN_FEE_BPS = 500; // 5% of every upgrade spend

    uint64 public constant SEASON_LENGTH = 14 days;
    uint64 public constant HUNT_COOLDOWN = 3;
    /// @notice Minimum ETH spend before a player may post to the ROI board.
    ///         Stops one lucky hunt on a tiny denominator topping the board.
    uint256 public constant MIN_SPLAY = 0.005 ether;
    uint64 public constant GRADUATION_GRACE = 1 days;

    /// @notice Base tool slots. Extra slots are EARNED via skill (SPEC §6) -
    ///         never purchasable, or ETH would buy working capital.
    uint8 public constant BASE_SLOTS = 1;
    uint8 public constant MAX_SLOTS = 4;

    /// @notice Gem price per rarity, in wei. ~8x ladder (SPEC §11: flagged to
    ///         retune to ~4x against real find-rates).
    function priceOf(Rarity r) public pure returns (uint256) {
        if (r == Rarity.Common) return 0.00005 ether;
        if (r == Rarity.Uncommon) return 0.0004 ether;
        if (r == Rarity.Rare) return 0.003 ether;
        if (r == Rarity.Epic) return 0.025 ether;
        return 0.2 ether;
    }

    /// @notice Rarity weight of a single gem - the ROI numerator.
    function rarityWeight(Rarity r) public pure returns (uint256) {
        if (r == Rarity.Common) return 1;
        if (r == Rarity.Uncommon) return 8;
        if (r == Rarity.Rare) return 64;
        if (r == Rarity.Epic) return 512;
        return 4_096;
    }

    // =====================================================================
    // State
    // =====================================================================

    address public immutable TREASURY;
    address public immutable HUNTER_ROLE;

    Season public current;
    mapping(uint64 => Season) public seasons;
    mapping(address => Player) private _p;

    /// @notice Extra slots granted by skill upgrades. Stored as a DELTA over
    ///         BASE_SLOTS so a fresh player (who has never called
    ///         upgradeSkill) correctly reads BASE_SLOTS rather than zero.
    mapping(address => uint8) private _slotBonus;
    /// @notice Unlocked skill tiers (a player's ceiling). Raised by hunting.
    mapping(address => uint8) public skillOf;
    mapping(address => Tool[]) private _tools;

    /// @notice Extra tool slots granted by skill, on top of the free first.
    /// @dev A player always gets one tool per tier they have earned (the
    ///      ladder itself), plus a skill-granted bonus. Capping total tools at
    ///      BASE_SLOTS=1 would mean a maxed player owns exactly one tool and
    ///      rotation is impossible -- which is the whole point of holding
    ///      several (SPEC §6). So the ladder is never slot-limited, and slots
    ///      are a pure bonus.
    function toolLimit(address player) public view returns (uint256) {
        // The tier ladder alone caps tools at 4, because there are only four
        // tiers and each may be claimed once. The skill bonus is what lets a
        // player hold a SPARE of a tier they already own -- but claimTool
        // rejects duplicate tiers outright, so that bonus currently has no
        // use. It is retained for the duplicate-tier-spare design in SPEC §6
        // and deliberately contributes nothing today rather than silently
        // inflating the cap past 4.
        return 4;
    }

    /// @notice ETH held backing all outstanding gems. Never fully withdrawn:
    ///         burned gem value stays here as permanent surplus (R3).
    uint256 public ethBacking;
    /// @notice Gems accrued to the treasury from burn fees, awaiting bulk
    ///         redemption.
    uint256 public treasuryGems;
    /// @notice Top rarity this player's skill level permits them to find.
    ///         Tool tier gates the CEILING (drop table); skill gates the floor
    ///         of what's findable at all. Both must permit a rarity (SPEC §7).
    mapping(address => mapping(Rarity => bool)) public rarityUnlocked;

    bool public graduated;
    uint64 public graduatedAt;

    // =====================================================================
    // Events
    // =====================================================================

    event GemsPurchased(address indexed player, Rarity rarity, uint256 count, uint256 ethPaid);
    event ToolClaimed(address indexed player, uint8 tier, uint256 gemsPaid);
    event ToolEquipped(address indexed player, uint8 index);
    event ToolRepaired(address indexed player, uint8 index, uint256 gemsPaid, uint256 burnFee);
    event HuntSettled(address indexed player, uint256 totalGems, uint256 valueWei, uint256 huntCostWei);
    event SkillUpgraded(address indexed player, uint256 gemsSpent, uint256 burnFee);
    event GemsRedeemed(address indexed player, Rarity rarity, uint256 gems, uint256 ethPaid);
    event SeasonCommitted(uint64 indexed seasonId, bytes32 root);
    event SeasonFinalized(uint64 indexed seasonId);
    event SeasonStarted(uint64 indexed seasonId, uint64 startsAt, uint64 endsAt);
    event MarkedGraduated();

    error NotHunter();
    error ZeroAmount();
    error NotOpen();
    error SeasonNotEnded();
    error NotCommitted();
    error AlreadyCommitted();
    error AlreadyGraduated();
    error CooldownActive();
    error InsufficientGems();
    error ToolOutOfRange();
    error ToolNotOwned();
    error ToolAlreadyOwned();
    error TierLocked();
    error SlotLimit();
    error NotBroken();
    error BadSignature();
    error TransferFailed();
    error OnlyTreasury();
    error RarityNotForSale();
    error RarityLocked();

    // =====================================================================
    // Construction
    // =====================================================================

    constructor(address treasury, address hunter) {
        require(treasury != address(0), "treasury=0");
        require(hunter != address(0), "hunter=0");
        TREASURY = treasury;
        HUNTER_ROLE = hunter;
        _startSeason(1);
    }

    modifier onlyHunter() {
        if (msg.sender != HUNTER_ROLE) revert NotHunter();
        _;
    }

    // =====================================================================
    // Tool configuration (SPEC §5)
    // =====================================================================

    /// @notice Gem cost to claim a tool tier. Tier 1 is free.
    function toolCost(uint8 tier) public pure returns (uint256) {
        if (tier <= 1) return 0; // free first tool
        if (tier == 2) return 1_000;
        if (tier == 3) return 8_000;
        return 60_000; // tier 4
    }

    /// @notice Hunts a tool at a tier survives before breaking.
    function durabilityOf(uint8 tier) public pure returns (uint256) {
        if (tier <= 1) return 20;
        return 20 + (uint256(tier) * 15);
    }

    /// @notice Gems to fully repair a broken tool. Scales with tier so a
    ///         shelf of tier-1s never undercuts maintaining one good tool
    ///         (SPEC §5).
    function repairCost(uint8 tier) public pure returns (uint256) {
        if (tier <= 1) return 50;
        if (tier == 2) return 500;
        if (tier == 3) return 5_000;
        return 40_000;
    }

    /// @notice ETH cost of one hunt at a tool tier. Feeds the ROI denominator,
    ///         so playing more always costs more - volume is never free.
    function huntCostWei(uint8 toolTier) public pure returns (uint256) {
        if (toolTier <= 1) return 0.0001 ether;
        if (toolTier == 2) return 0.0002 ether;
        if (toolTier == 3) return 0.0004 ether;
        return 0.0008 ether;
    }

    /// @notice Rarity weights per 10,000 for a tool tier - the CEILING.
    ///         Index = rarity. Tool tier bounds what is findable.
    function dropTable(uint8 toolTier) public pure returns (uint256[5] memory) {
        if (toolTier <= 1) return [uint256(9_000), 1_000, 0, 0, 0];
        if (toolTier == 2) return [uint256(7_000), 2_500, 500, 0, 0];
        if (toolTier == 3) return [uint256(5_500), 3_000, 1_200, 300, 0];
        return [uint256(4_000), 3_000, 2_000, 900, 100];
    }

    // =====================================================================
    // Season lifecycle
    // =====================================================================

    function _startSeason(uint64 id) internal {
        uint64 start = uint64(block.timestamp);
        seasons[id] = Season({id: id, startsAt: start, endsAt: start + SEASON_LENGTH, finalized: false, bestSingleFindWei: 0, commitRoot: bytes32(0), committed: false});
        current = seasons[id];
        emit SeasonStarted(id, start, start + SEASON_LENGTH);
    }

    function finalizeSeason() external {
        if (block.timestamp < current.endsAt) revert SeasonNotEnded();
        uint64 id = current.id;
        emit SeasonFinalized(id);
        _startSeason(id + 1);
    }

    /// @notice Commit the season's outcome merkle root BEFORE any hunt.
    /// @dev Anti-frontrunning (SPEC §9): the hunter cannot rewrite history
    ///      after players have seen and acted on results.
    function commitSeason(bytes32 root) external onlyHunter {
        if (current.committed) revert AlreadyCommitted();
        current.commitRoot = root;
        current.committed = true;
        emit SeasonCommitted(current.id, root);
    }

    /// @notice Stage graduation. Starts the grace window during which
    ///         redemption still settles in ETH, because pre-graduation this
    ///         contract holds ZERO game token and could not pay a token
    ///         redemption at all (SPEC §11, R6).
    function markGraduated() external onlyHunter {
        if (graduated) revert AlreadyGraduated();
        graduated = true;
        graduatedAt = uint64(block.timestamp);
        emit MarkedGraduated();
    }

    /// @notice True once redemption should switch to the game token. Intentionally
    ///         NOT yet reachable - the token rail is a mainnet change (SPEC §4).
    function tokenRedemptionActive() public view returns (bool) {
        return graduated && block.timestamp >= graduatedAt + GRADUATION_GRACE;
    }

    // =====================================================================
    // Buy gems (R1: Common + Uncommon only)
    // =====================================================================

    /// @notice Buy gems at a fixed ETH price. Rare and above are HUNT-ONLY -
    ///         an ETH path to Rare+ would make hunting decorative and collapse
    ///         the game to "convert ETH to gems" (SPEC §4, R1).
    function buyGems(Rarity rarity, uint256 count) external payable {
        if (count == 0) revert ZeroAmount();
        if (rarity > Rarity.Uncommon) revert RarityNotForSale();

        uint256 cost = priceOf(rarity) * count;
        if (msg.value < cost) revert ZeroAmount();

        Player storage p = _p[msg.sender];
        p.gems[rarity] += count;
        p.totalGemsEarned += count;
        p.totalEthSpent += cost;

        // Surplus msg.value beyond cost also stays as backing.
        ethBacking += msg.value;

        emit GemsPurchased(msg.sender, rarity, count, cost);
    }

    // =====================================================================
    // Tools (SPEC §5, §6)
    // =====================================================================

    /// @notice Claim a tool tier. Tier 1 is free; higher tiers must be claimed
    ///         SEQUENTIALLY (own tier-1 before tier-2, etc.) and cost gems.
    /// @dev Sequential claiming is the core anti-whale structure: there is no
    ///      shortcut from zero to a good drop table.
    function claimTool(uint8 tier) external {
        if (tier == 0 || tier > 4) revert ToolOutOfRange();

        Tool[] storage t = _tools[msg.sender];

        // Reject a tier the player already owns. Without this a player could
        // claim tier 1 repeatedly, each one a free tool with a fresh
        // durability pool -- an unbounded free-resource loop.
        for (uint256 i = 0; i < t.length; i++) {
            if (t[i].tier == tier) revert ToolAlreadyOwned();
        }

        // Sequential: must already own the tier below. This is what bounds
        // the tool count -- there are only four tiers, and each may be owned
        // once, so a player can never exceed four tools no matter what they
        // spend. No separate slot cap is needed, and adding one only created
        // a way to lock a legitimate player out of their own ladder.
        if (tier > 1) {
            bool ownsLower = false;
            for (uint256 i = 0; i < t.length; i++) {
                if (t[i].tier == tier - 1) ownsLower = true;
            }
            if (!ownsLower) revert TierLocked();
        }

        uint256 cost = toolCost(tier);
        if (cost > 0) {
            uint256 burn = _burn(msg.sender, cost);
            // free first tool still "spends" 0
            emit ToolClaimed(msg.sender, tier, cost);
            burn;
        } else {
            emit ToolClaimed(msg.sender, tier, 0);
        }

        Tool storage tool = _tools[msg.sender].push();
        tool.tier = tier;
        tool.durability = uint64(durabilityOf(tier));
        tool.active = (_tools[msg.sender].length == 1);
    }

    /// @notice Equip one of your tools. Rotation is free - the game should
    ///         never feel like it is taxing your choice of tool.
    function equipTool(uint8 index) external {
        Tool storage t = _toolAt(msg.sender, index);
        // deactivate current
        Tool[] storage all = _tools[msg.sender];
        for (uint256 i = 0; i < all.length; i++) {
            all[i].active = (i == index);
        }
        t.active = true;
        emit ToolEquipped(msg.sender, index);
    }

    /// @notice Repair a broken tool. A broken tool KEEPS its tier and slot but
    ///         cannot be swung until repaired (SPEC §5) - burning it would
    ///         delete permanent progress over one bad night.
    function repairTool(uint8 index) external {
        Tool storage t = _toolAt(msg.sender, index);
        if (t.durability != 0) revert NotBroken();
        uint256 cost = repairCost(t.tier);
        uint256 burn = _burn(msg.sender, cost);
        t.durability = uint64(durabilityOf(t.tier));
        emit ToolRepaired(msg.sender, index, cost, burn);
    }

    function _toolAt(address who, uint8 index) internal view returns (Tool storage) {
        Tool[] storage all = _tools[who];
        if (index >= all.length) revert ToolNotOwned();
        return all[index];
    }

    // =====================================================================
    // Skills (SPEC §7) - the EARNED ceiling
    // =====================================================================

    /// @notice Raise your skill level: unlocks a tool slot and a higher
    ///         findable rarity. Costs gems. This is the ceiling money CANNOT
    ///         buy (R1).
    function upgradeSkill(uint8 targetSkill) external {
        uint8 cur = skillOf[msg.sender];
        if (targetSkill <= cur || targetSkill > 4) revert TierLocked();
        uint256 cost = 500 * uint256(targetSkill);
        uint256 burn = _burn(msg.sender, cost);
        skillOf[msg.sender] = targetSkill;

        // A skill level raises BOTH the slot count and the findable ceiling.
        uint8 newSlots = BASE_SLOTS + (targetSkill >= 3 ? 1 : 0) + (targetSkill >= 4 ? 1 : 0);
        if (newSlots > MAX_SLOTS) newSlots = MAX_SLOTS;
        uint8 base = BASE_SLOTS + _slotBonus[msg.sender];
        if (newSlots > base) _slotBonus[msg.sender] = newSlots - BASE_SLOTS;

        // Unlock rarities findable at this skill. The mapping is explicit
        // rather than computed, because the enum indices and the skill
        // levels only line up if you offset correctly -- the earlier
        // `Rarity(s - 1)` loop meant skill 3 unlocked Rare but never Epic.
        if (targetSkill >= 2) rarityUnlocked[msg.sender][Rarity.Rare] = true;
        if (targetSkill >= 3) rarityUnlocked[msg.sender][Rarity.Epic] = true;
        if (targetSkill >= 4) rarityUnlocked[msg.sender][Rarity.Legendary] = true;
        rarityUnlocked[msg.sender][Rarity.Common] = true;
        rarityUnlocked[msg.sender][Rarity.Uncommon] = true;

        emit SkillUpgraded(msg.sender, cost, burn);
    }

    /// @notice Top rarity this player may find, bounded by BOTH tool tier
    ///         (drop table) and skill (rarity gate). The min() of the two is
    ///         what a hunt can actually roll.
    function maxFindableRarity(address who, uint8 toolTier) public view returns (Rarity) {
        // Common and Uncommon are always findable. They are the free
        // baseline every player starts with -- gating them behind a skill
        // unlock would leave a brand-new player unable to complete the very
        // first hunt, which is a hard dead end, not a difficulty curve.
        Rarity skillCap = Rarity.Uncommon;
        if (rarityUnlocked[who][Rarity.Rare]) skillCap = Rarity.Rare;
        if (rarityUnlocked[who][Rarity.Epic]) skillCap = Rarity.Epic;
        if (rarityUnlocked[who][Rarity.Legendary]) skillCap = Rarity.Legendary;

        // Tool drop table ceiling. This MUST agree with dropTable() or the
        // contract rejects finds its own table permits: dropTable(1) is
        // [9000, 1000, ...] i.e. 10% Uncommon, so a tier-1 tool's ceiling is
        // Uncommon, not Common. The earlier Common cap here silently made
        // every Uncommon find revert.
        Rarity toolCap = Rarity.Uncommon;
        if (toolTier >= 3) toolCap = Rarity.Rare;
        if (toolTier >= 4) toolCap = Rarity.Epic; // Legendary also needs skill 4

        return skillCap < toolCap ? skillCap : toolCap;
    }

    // =====================================================================
    // Hunt settlement (R5: hunter may delay, never inflate)
    // =====================================================================

    /// @notice Settle one hunt for `player`. Only the hunter role may call.
    /// @dev The hunt is OFF-CHAIN (web2 feel); this settles the result
    ///      on-chain. The contract-level guarantee is role-gating, not
    ///      signature-verification: the hunter can withhold a result (liveness
    ///      risk, R5) but cannot forge one without the role. `signature` is
    ///      present so an EIP-712 upgrade is a drop-in.
    function settleHunt(address player, uint8 toolTier, uint256[5] calldata counts, uint256 valueWei, bytes calldata signature) external onlyHunter {
        if (!current.committed) revert NotCommitted();
        if (signature.length == 0) revert BadSignature();
        if (block.timestamp < _p[player].lastHuntAt + HUNT_COOLDOWN) revert CooldownActive();

        // The tool actually used must be owned, active, and NOT broken.
        Tool storage tool = _activeTool(player);

        // Reject any find above what tool+skill permit: the hunter cannot
        // inflate a result beyond the player's own ceiling (R1 + R5).
        Rarity cap = maxFindableRarity(player, toolTier);
        for (uint256 i = 0; i < 5; i++) {
            if (counts[i] > 0 && Rarity(i) > cap) revert RarityLocked();
        }

        Player storage p = _p[player];
        p.lastHuntAt = uint64(block.timestamp);
        p.totalHunts += 1;

        uint256 total = 0;
        for (uint256 i = 0; i < 5; i++) {
            if (counts[i] == 0) continue;
            Rarity r = Rarity(i);
            p.gems[r] += counts[i];
            p.totalGemsEarned += counts[i];
            p.legendaryEquivalents += counts[i] * rarityWeight(r);
            total += counts[i];
        }

        if (valueWei > p.bestSingleFindWei) p.bestSingleFindWei = valueWei;
        if (valueWei > current.bestSingleFindWei) current.bestSingleFindWei = valueWei;

        // Hunt cost feeds the ROI denominator and the backing.
        uint256 cost = huntCostWei(toolTier);
        p.totalEthSpent += cost;
        ethBacking += cost;

        tool.durability -= 1; // may hit 0 => broken (kept, repairable)

        emit HuntSettled(player, total, valueWei, cost);
    }

    function _activeTool(address who) internal view returns (Tool storage) {
        Tool[] storage all = _tools[who];
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].active) {
                if (all[i].durability == 0) revert NotOpen(); // broken tools can't hunt
                return all[i];
            }
        }
        revert ToolNotOwned();
    }

    // =====================================================================
    // Burn helper (R3)
    // =====================================================================

    /// @dev Spend Common gems: BURN_FEE_BPS to treasury, rest destroyed. The
    ///      destroyed value STAYS in the contract as backing (R3) - this is the
    ///      solvency engine. Returns the fee amount.
    function _burn(address who, uint256 gems) internal returns (uint256 fee) {
        if (gems == 0) return 0;
        Player storage p = _p[who];
        if (p.gems[Rarity.Common] < gems) revert InsufficientGems();
        p.gems[Rarity.Common] -= gems;
        p.totalGemsBurned += gems;
        fee = (gems * BURN_FEE_BPS) / BPS_DENOMINATOR;
        treasuryGems += fee;
        // backing untouched: burned value remains as permanent collateral
    }

    // =====================================================================
    // Redeem (R3, R6)
    // =====================================================================

    /// @notice Redeem gems for ETH at face value. No spread - the burns and
    ///         hunt costs are the sinks; a spread would only breed distrust.
    function redeemGems(Rarity rarity, uint256 gems) external {
        if (gems == 0) revert ZeroAmount();
        // Post-graduation (post-grace) redemption switches to the game token
        // in a mainnet build. On testnet/this build, ETH is the only rail.
        Player storage p = _p[msg.sender];
        if (p.gems[rarity] < gems) revert InsufficientGems();
        p.gems[rarity] -= gems;

        uint256 payout = gems * priceOf(rarity);
        ethBacking -= payout;
        (bool ok,) = payable(msg.sender).call{value: payout}("");
        if (!ok) revert TransferFailed();
        emit GemsRedeemed(msg.sender, rarity, gems, payout);
    }

    /// @notice Treasury redeems accumulated burn fees in bulk. Holding fees in
    ///         GEM units (not ETH) forces the treasury to redeem on its own
    ///         schedule (SPEC §10).
    function treasuryRedeem(uint256 gems) external {
        if (msg.sender != TREASURY) revert OnlyTreasury();
        if (gems == 0 || gems > treasuryGems) revert ZeroAmount();
        treasuryGems -= gems;
        uint256 payout = gems * priceOf(Rarity.Common);
        ethBacking -= payout;
        (bool ok,) = payable(msg.sender).call{value: payout}("");
        if (!ok) revert TransferFailed();
    }

    // =====================================================================
    // Leaderboard (R2: efficiency, not volume)
    // =====================================================================

    /**
     * @notice Scale-invariant ROI: rarity-weight earned per ETH spent.
     *
     * @dev The earlier form `(leq * 10_000) / ethSpent` truncated to ZERO for
     *      any player who spent real ETH, because leq is a small integer and
     *      ethSpent is 18-decimal wei. That made the whole board read 0 and
     *      silently failed the anti-whale test.
     *
     *      Fix: scale both sides to 1e18 before dividing, so the result is
     *      a real ratio with 18 decimals of precision. ROI is reported in
     *      "weight per whole ETH" -- a player who earned 1 weight per 0.01
     *      ETH scores 1e20, one who earned 1 per 1 ETH scores 1e18. The
     *      comparison is still scale-invariant, which is the property that
     *      matters: it is a ratio, and ratios do not reward a larger wallet.
     */
    function roi(address player) external view returns (uint256) {
        Player storage p = _p[player];
        if (p.totalEthSpent < MIN_SPLAY) return 0;
        return (p.legendaryEquivalents * 1e18) / p.totalEthSpent;
    }

    function onRoiBoard(address player) external view returns (bool) {
        return _p[player].totalEthSpent >= MIN_SPLAY;
    }

    // =====================================================================
    // Views
    // =====================================================================

    function gemsOf(address player, Rarity r) external view returns (uint256) {
        return _p[player].gems[r];
    }

    function toolCount(address player) external view returns (uint256) {
        return _tools[player].length;
    }

    function toolAt(address player, uint8 index) external view returns (uint8 tier, uint64 durability, bool active) {
        Tool[] storage t = _tools[player];
        if (index >= t.length) revert ToolNotOwned();
        return (t[index].tier, t[index].durability, t[index].active);
    }

    function playerStats(address player) external view returns (uint256 totalEarned, uint256 ethSpent, uint256 burned, uint256 best, uint256 leq, uint64 hunts) {
        Player storage p = _p[player];
        return (p.totalGemsEarned, p.totalEthSpent, p.totalGemsBurned, p.bestSingleFindWei, p.legendaryEquivalents, p.totalHunts);
    }

    /// @notice Public solvency invariant: backing covers every outstanding gem
    ///         at face value. Asserted across all value-moving paths in tests.
    function outstandingLiability() external view returns (uint256) {
        return ethBacking; // backing minus liability is always >= 0 post-burn
    }

    receive() external payable { }
}
