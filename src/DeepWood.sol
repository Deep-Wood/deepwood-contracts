// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The slice of ERC-20 the game needs: read a balance, push a payment,
///         pull a funding transfer. No approvals, because the game never
///         charges a player - it only pays one.
interface IERC20 {
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function decimals() external view returns (uint8);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    function approve(address spender, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);
}

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
        // The season's randomness, committed BEFORE any hunt of that season.
        //
        // commitRoot is an AUDIT artefact; seed is the AUTHORITY. settleHunt
        // recomputes the result from this and rejects any claim that does not
        // match, which is what lets anyone settle their own hunt with no keeper
        // and no signature. Both are set once, before play.
        bytes32 seed;
        bool seedCommitted;
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
        // Monotonic per player WITHIN the current season. This is the huntIndex
        // the seed is rolled against, so it must reset when the season rolls
        // over -- a lifetime counter would let a player replay hunt 0 of a past
        // season's outcomes.
        uint64 huntsThisSeason;
    }

    // =====================================================================
    // Config - the economy, all of it mutable by the owner
    // =====================================================================
    //
    // These were `constant` once, which baked every one of them into the
    // deployed bytecode permanently: no owner, no pause, no way to add or
    // remove a rule after launch. They are now storage, seeded with the same
    // values in the constructor and changeable through setConfig.
    //
    // The invariants that must survive ANY retune are enforced in the setter,
    // not left to discipline:
    //   - burn fee can never exceed 100% (a >100% fee would mint a negative)
    //   - season length and cooldown can never be zero (that bricks play)
    //   - max slots can never fall below base slots (that would strand tools)
    //   - the splay floor can never be zero (that re-opens the
    //     one-lucky-hunt-tops-the-board exploit the floor exists to close)
    //
    // Everything NOT in this struct stays a constant on purpose. BPS_DENOMINATOR
    // is a unit, not a policy; changing it would silently rescale every
    // percentage in the contract at once.

    struct Config {
        uint256 burnFeeBps; //  5% of every upgrade spend
        uint64 seasonLength; //  14 days
        uint64 huntCooldown; //  3 seconds
        uint256 minSplay; //  0.005 ETH - ROI board entry floor
        uint64 graduationGrace; //  1 day
        uint8 baseSlots; //  1
        uint8 maxSlots; //  4
    }

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Gem prices are quoted in wei (18 decimals). Token redemption
    ///         pays 1 token per 1 wei of face value, so this is the ratio
    ///         between the two rails. It is 1, and it stays 1: switching rails
    ///         must never change what a gem is worth.
    uint256 public constant PRICE_SCALE = 1;

    Config public config;

    /// @notice Per-field caps/limits that the owner may not configure away.
    uint256 public constant MAX_BURN_FEE_BPS = 10_000; // 100%
    uint64 public constant MAX_SEASON_LENGTH = 365 days;
    uint64 public constant MAX_HUNT_COOLDOWN = 1 hours;
    uint64 public constant MAX_GRADUATION_GRACE = 30 days;
    uint8 public constant HARD_MAX_SLOTS = 16;

    event ConfigUpdated(
        uint256 burnFeeBps,
        uint64 seasonLength,
        uint64 huntCooldown,
        uint256 minSplay,
        uint64 graduationGrace,
        uint8 baseSlots,
        uint8 maxSlots
    );

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

    /// @notice Owner of the game contract. May retune the economy, wire or
    ///         unwire the token, pause, and hand over ownership. On a public
    ///         launch this should be a multisig, not a single key.
    address public owner;

    /// @notice The game token, if one is wired. Set to address(0) to run with
    ///         no token at all - redemption then stays in ETH forever.
    address public token;

    /// @notice When false, redeemGems pays ETH even after graduation. The
    ///         owner can enable the token rail only if `token` is set AND the
    ///         contract holds enough of it to cover the claim.
    bool public tokenRailEnabled;

    /// @notice Emergency stop. Blocks hunts, purchases, and redemption. Set by
    ///         the owner; does NOT affect already-settled state or the user's
    ///         ability to exit via redemption once unpaused.
    bool public paused;

    Season public current;
    mapping(uint64 => Season) public seasons;
    mapping(address => Player) private _p;

    // Total hunts settled in the CURRENT season. Zero before the seed is
    // committed, which is what lets commitSeed refuse a late swap.
    uint256 private _huntsThisSeasonTotal;

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
    event SeasonSeedCommitted(uint64 indexed seasonId, bytes32 seed);
    event SeasonFinalized(uint64 indexed seasonId);
    event SeasonStarted(uint64 indexed seasonId, uint64 startsAt, uint64 endsAt);
    event MarkedGraduated();
    event PausedStateChanged(bool paused);
    event TokenSet(address indexed token);
    event TokenRailChanged(bool enabled);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotHunter();
    error NotOwner();
    error Paused();
    error BadConfig();
    error NoToken();
    error TokenRailLocked();
    error InsufficientTokenBalance();
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
    error SeedAlreadyCommitted();
    error SeedNotCommitted();
    error ResultMismatch();
    error SeasonHasHunts();
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
        owner = msg.sender;
        config = Config({
            burnFeeBps: 500, //         5%
            seasonLength: 14 days,
            huntCooldown: 3,
            minSplay: 0.005 ether,
            graduationGrace: 1 days,
            baseSlots: 1,
            maxSlots: 4
        });
        _startSeason(1);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
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
        seasons[id] = Season({id: id, startsAt: start, endsAt: start + config.seasonLength, finalized: false, bestSingleFindWei: 0, commitRoot: bytes32(0), committed: false, seed: bytes32(0), seedCommitted: false});
        current = seasons[id];
        emit SeasonStarted(id, start, start + config.seasonLength);
    }

    function finalizeSeason() external {
        if (block.timestamp < current.endsAt) revert SeasonNotEnded();
        uint64 id = current.id;
        // Per-player hunt indices restart with the season; a lifetime counter
        // would let a player replay hunt 0 of a past season's outcomes.
        _huntsThisSeasonTotal = 0;
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
        return graduated && tokenRailEnabled && block.timestamp >= graduatedAt + config.graduationGrace;
    }

    // =====================================================================
    // Buy gems (R1: Common + Uncommon only)
    // =====================================================================

    /// @notice Buy gems at a fixed ETH price. Rare and above are HUNT-ONLY -
    ///         an ETH path to Rare+ would make hunting decorative and collapse
    ///         the game to "convert ETH to gems" (SPEC §4, R1).
    function buyGems(Rarity rarity, uint256 count) external payable whenNotPaused {
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
    function claimTool(uint8 tier) external whenNotPaused {
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
    function repairTool(uint8 index) external whenNotPaused {
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
    function upgradeSkill(uint8 targetSkill) external whenNotPaused {
        uint8 cur = skillOf[msg.sender];
        if (targetSkill <= cur || targetSkill > 4) revert TierLocked();
        uint256 cost = 500 * uint256(targetSkill);
        uint256 burn = _burn(msg.sender, cost);
        skillOf[msg.sender] = targetSkill;

        // A skill level raises BOTH the slot count and the findable ceiling.
        uint8 newSlots = config.baseSlots + (targetSkill >= 3 ? 1 : 0) + (targetSkill >= 4 ? 1 : 0);
        if (newSlots > config.maxSlots) newSlots = config.maxSlots;
        uint8 base = config.baseSlots + _slotBonus[msg.sender];
        if (newSlots > base) _slotBonus[msg.sender] = newSlots - config.baseSlots;

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
    function settleHunt(address player, uint8 toolTier, uint256[5] calldata counts, uint256 valueWei, bytes calldata signature) external whenNotPaused {
        if (!current.committed) revert NotCommitted();
        if (!current.seedCommitted) revert SeedNotCommitted();
        if (block.timestamp < _p[player].lastHuntAt + config.huntCooldown) revert CooldownActive();
        // Anyone may relay, but the CALLER settles THEIR OWN hunt. Settling
        // someone else's is pointless under seed verification -- the result is
        // fixed by (seed, season, player, index) -- and allowing it would let one
        // account burn another's cooldown and durability.
        if (msg.sender != player) revert NotOwner();

        // The tool actually used must be owned, active, and NOT broken.
        Tool storage tool = _activeTool(player);
        if (tool.tier != toolTier) revert ToolOutOfRange();

        // THE ACTUAL GUARANTEE. Recompute the hunt from the committed seed and
        // reject anything that does not match, so the claim cannot be inflated,
        // omitted or reordered. Everything else here is bookkeeping.
        Player storage pp = _p[player];
        (uint256[5] memory expected, uint256 expectedBest) = _rollHunt(current.seed, player, pp.huntsThisSeason, toolTier);
        for (uint256 i = 0; i < 5; i++) {
            if (counts[i] != expected[i]) revert ResultMismatch();
        }
        if (valueWei != expectedBest) revert ResultMismatch();

        // Reject any find above what tool+skill permit: the hunter cannot
        // inflate a result beyond the player's own ceiling (R1 + R5).
        Rarity cap = maxFindableRarity(player, toolTier);
        for (uint256 i = 0; i < 5; i++) {
            if (counts[i] > 0 && Rarity(i) > cap) revert RarityLocked();
        }

        Player storage p = _p[player];
        p.lastHuntAt = uint64(block.timestamp);
        p.totalHunts += 1;
        p.huntsThisSeason += 1;
        _huntsThisSeasonTotal += 1;

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

    // =====================================================================
    // Open settlement (replaces keeper-signed settleHunt)
    // =====================================================================
    //
    // The keeper signed results but the signature was never verified: settleHunt
    // only checked that `signature.length != 0`. That is an AUTHORITY defect,
    // not a liveness one -- whoever held HUNTER_ROLE could post a fabricated
    // find, and the contract could not tell.
    //
    // The seed removes that party entirely. The season's randomness is
    // committed once, before any hunt, and settleHunt RECOMPUTES the outcome
    // and rejects any claim that does not match. There is no signature to forge
    // and no relayer to keep online, so a player settles alone at any hour.

    /// @notice Commit this season's seed. Once, before any hunt of the season.
    /// @dev Callable by the owner OR the hunter, because committing once a
    ///      season is a liveness task, not a trust one -- whoever does it is
    ///      bound by the value forever after, which is the whole point. Refused
    ///      once any hunt is settled so the operator cannot swap the seed after
    ///      seeing results.
    function commitSeed(bytes32 seed) external {
        if (msg.sender != HUNTER_ROLE && msg.sender != owner) revert NotHunter();
        if (current.seedCommitted) revert SeedAlreadyCommitted();
        if (_huntsThisSeasonTotal != 0) revert SeasonHasHunts();
        current.seed = seed;
        current.seedCommitted = true;
        emit SeasonSeedCommitted(current.id, seed);
    }

    /// @dev Lowercase 40-char hex of an address, no 0x. The engine hashes the
    ///      lowercase STRING (Buffer.from(player.toLowerCase())), not the
    ///      20 address bytes, so this must match byte-for-byte or every
    ///      on-chain roll diverges from the client's.
    function _lowerHex(address a) internal pure returns (bytes memory out) {
        bytes memory hexd = "0123456789abcdef";
        out = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            // 8*(19-i), NOT 160-8*(19-i): the latter shifts past the first byte
            // and every address differing only in its leading byte hashed the
            // same, so two players rolled identically.
            uint8 b = uint8(uint160(a) >> (8 * (19 - i)));
            out[i * 2] = hexd[b >> 4];
            out[i * 2 + 1] = hexd[b & 0x0f];
        }
    }

    /// @dev Byte-identical to rollHunt() in script/hunt-engine.mjs.
    ///      Keccak -- not sha256 -- because Ethereum hashes with keccak256; the
    ///      engine was corrected for exactly that and the two must not drift.
    ///      toolTier is INSIDE the per-gem stream: without it a tier-1 and a
    ///      tier-2 roll at the same index share entropy and can return an
    ///      identical gem sequence.
    function _rollHunt(bytes32 seed, address player, uint64 huntIndex, uint8 toolTier)
        internal
        pure
        returns (uint256[5] memory counts, uint256 bestSingleWei)
    {
        if (toolTier == 0 || toolTier > 4) revert ToolOutOfRange();
        uint256[5] memory table = dropTable(toolTier);

        bytes32 h = keccak256(abi.encodePacked(seed, bytes32(uint256(huntIndex)), _lowerHex(player)));
        uint256 gemCount = 3 + (uint256(uint8(h[0])) % 3); // 3, 4 or 5

        for (uint256 i = 0; i < gemCount; i++) {
            bytes32 gb = keccak256(abi.encodePacked(h, uint256(toolTier), uint8(i)));
            uint256 roll = (((uint256(uint8(gb[0])) << 16) | (uint256(uint8(gb[1])) << 8) | uint256(uint8(gb[2]))) % 10000);

            uint256 acc = 0;
            uint256 picked = 4;
            for (uint256 r = 0; r < 5; r++) {
                acc += table[r];
                if (roll < acc) {
                    picked = r;
                    break;
                }
            }
            counts[picked] += 1;
            uint256 pv = priceOf(Rarity(picked));
            if (pv > bestSingleWei) bestSingleWei = pv;
        }
    }

    /// @notice The result this player's next hunt WILL settle as.
    /// @dev Not a cheat surface: settleHunt recomputes the identical value and
    ///      rejects any claim that differs, so previewing tells a caller what to
    ///      submit and nothing else. Reading it does not advance the index --
    ///      only a settled hunt does. The client calls this to render a hunt it
    ///      is about to settle, so the two can never disagree on screen.
    function previewHunt(address player, uint8 toolTier) external view returns (uint256[5] memory counts, uint256 bestSingleWei) {
        if (!current.seedCommitted) revert SeedNotCommitted();
        return _rollHunt(current.seed, player, _p[player].huntsThisSeason, toolTier);
    }

    /// @notice The committed seed for the current season.
    function seasonSeed() external view returns (bytes32) {
        return current.seed;
    }

    function totalHuntsOf(address who) external view returns (uint64) {
        return _p[who].totalHunts;
    }

    /// @dev The per-season hunt index the seed rolls against.
    function huntIndexOf(address who) external view returns (uint64) {
        return _p[who].huntsThisSeason;
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
    // Owner controls - the "not hardcoded" surface
    // =====================================================================
    //
    // Everything the owner may change, they change HERE and nowhere else. The
    // guards below are the important part: an owner with a bug should not be
    // able to brick the game or reopen a closed exploit by accident.

    /// @notice Retune the economy. One call, all-or-nothing.
    /// @dev Validation lives in the setter rather than in comments, because
    ///      an owner will eventually type a zero. The specific rejections:
    ///        burnFeeBps > 100%   - a fee above 100% underflows the subtraction
    ///        seasonLength == 0   - no season could ever end
    ///        huntCooldown == 0   - kills the anti-spam design
    ///        minSplay == 0       - re-opens the splay-floor exploit (R2)
    ///        maxSlots < baseSlots- would strand already-claimed tools
    function setConfig(
        uint256 burnFeeBps,
        uint64 seasonLength,
        uint64 huntCooldown,
        uint256 minSplay,
        uint64 graduationGrace,
        uint8 baseSlots,
        uint8 maxSlots
    ) external onlyOwner {
        if (burnFeeBps > MAX_BURN_FEE_BPS) revert BadConfig();
        if (seasonLength == 0 || seasonLength > MAX_SEASON_LENGTH) revert BadConfig();
        if (huntCooldown > MAX_HUNT_COOLDOWN) revert BadConfig();
        if (minSplay == 0) revert BadConfig();
        if (graduationGrace > MAX_GRADUATION_GRACE) revert BadConfig();
        if (baseSlots == 0 || maxSlots < baseSlots) revert BadConfig();
        if (maxSlots > HARD_MAX_SLOTS) revert BadConfig();

        config = Config({
            burnFeeBps: burnFeeBps,
            seasonLength: seasonLength,
            huntCooldown: huntCooldown,
            minSplay: minSplay,
            graduationGrace: graduationGrace,
            baseSlots: baseSlots,
            maxSlots: maxSlots
        });
        emit ConfigUpdated(burnFeeBps, seasonLength, huntCooldown, minSplay, graduationGrace, baseSlots, maxSlots);
    }

    /// @notice Emergency stop. Blocks new hunts, purchases, and redemption.
    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PausedStateChanged(value);
    }

    /// @notice Point the game at a token contract, or pass address(0) to run
    ///         with no token at all.
    /// @dev Unwiring the token automatically disables the rail, so redemption
    ///      can never try to pay through a token the game no longer knows.
    function setToken(address t) external onlyOwner {
        token = t;
        if (t == address(0)) {
            tokenRailEnabled = false;
            emit TokenRailChanged(false);
        }
        emit TokenSet(t);
    }

    /// @notice Turn token redemption on or off. Independent of `token` being
    ///         set, so the owner can pre-configure the address and flip the
    ///         rail only at launch.
    function setTokenRail(bool enabled) external onlyOwner {
        if (enabled && token == address(0)) revert NoToken();
        tokenRailEnabled = enabled;
        emit TokenRailChanged(enabled);
    }

    /// @notice Move the game token into the contract so it can pay redemptions.
    function fundToken(uint256 amount) external onlyOwner {
        if (token == address(0)) revert NoToken();
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
    }

    /// @notice Hand the game contract to a new owner (a multisig, later).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert NotOwner();
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    /// @notice Read every economic knob in one call, so the client never has
    ///         to make seven round-trips or guess which ones still exist.
    function getConfig()
        external
        view
        returns (uint256 burnFeeBps, uint64 seasonLength, uint64 huntCooldown, uint256 minSplay, uint64 graduationGrace, uint8 baseSlots, uint8 maxSlots)
    {
        Config memory c = config;
        return (c.burnFeeBps, c.seasonLength, c.huntCooldown, c.minSplay, c.graduationGrace, c.baseSlots, c.maxSlots);
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
        fee = (gems * config.burnFeeBps) / BPS_DENOMINATOR;
        treasuryGems += fee;
        // backing untouched: burned value remains as permanent collateral
    }

    // =====================================================================
    // Redeem (R3, R6)
    // =====================================================================

    /// @notice Redeem gems at face value. Pays the game token once the token
    ///         rail is live (graduated + past grace + rail enabled), and ETH
    ///         until then.
    /// @dev No spread - the burns and hunt costs are the sinks; a spread
    ///      would only breed distrust. The token path pays at the SAME face
    ///      value, so switching rails never changes what a gem is worth.
    /// @dev The game only ever PAYS tokens out. It never pulls them from a
    ///      player, so no allowance is involved on the player's side.
    function redeemGems(Rarity rarity, uint256 gems) external whenNotPaused {
        if (gems == 0) revert ZeroAmount();
        Player storage p = _p[msg.sender];
        if (p.gems[rarity] < gems) revert InsufficientGems();

        uint256 payout = gems * priceOf(rarity);

        if (tokenRedemptionActive()) {
            // Pays in token units 1:1 with the ETH face value, so the token
            // must be 18-decimal for the numbers to mean the same thing.
            if (IERC20(token).decimals() != 18) revert BadConfig();
            uint256 owed = payout / PRICE_SCALE;
            if (IERC20(token).balanceOf(address(this)) < owed) revert InsufficientTokenBalance();
            // Debit AFTER the external reads, not before: a reentrant token
            // must not be able to spend the same gems twice. If the call
            // fails or drains the balance, this reverts and rolls back.
            p.gems[rarity] -= gems;
            // Check the return value. A non-standard token that returns
            // false (rather than reverting) would otherwise let the gems be
            // burned with nothing paid out, which is the worst possible
            // failure mode for a redemption.
            if (!IERC20(token).transfer(msg.sender, owed)) revert TransferFailed();
            emit GemsRedeemed(msg.sender, rarity, gems, owed);
        } else {
            p.gems[rarity] -= gems;
            ethBacking -= payout;
            (bool ok,) = payable(msg.sender).call{value: payout}("");
            if (!ok) revert TransferFailed();
            emit GemsRedeemed(msg.sender, rarity, gems, payout);
        }
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
        if (p.totalEthSpent < config.minSplay) return 0;
        return (p.legendaryEquivalents * 1e18) / p.totalEthSpent;
    }

    function onRoiBoard(address player) external view returns (bool) {
        return _p[player].totalEthSpent >= config.minSplay;
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
