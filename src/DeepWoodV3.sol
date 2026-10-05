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
contract DeepWoodV3 {
    // =====================================================================
    // Types
    // =====================================================================

    /// @notice Where the game is in its life. Replaces the old implicit
    ///         "seasonOpen bool, season 1 forever" model.
    ///
    ///         PRESEASON -- anyone may play from the moment the seed is
    ///           committed. No end date: the owner ends it when they choose, or
    ///           pauses and resumes it indefinitely. Nothing preseason counts
    ///           toward Season 1's leaderboard (see `seasonScore`).
    ///         LIVE -- Season 1 proper. Fixed length, auto-advances.
    ///         CLOSED -- the owner has ended the run entirely.
    enum Phase {
        Preseason,
        Live,
        Closed
    }

    enum Rarity {
        Common, //  0 Quartz
        Uncommon, //  1 Amber
        Rare, //  2 Sapphire
        Epic, //  3 Ruby
        Legendary //  4 Diamond
    }

    struct Season {
        uint64 id;
        /// 0 = preseason, 1 = a numbered season. Kept IN the struct rather than
        /// inferred from `id` so preseason (id 0) and Season 1 (id 1) cannot be
        /// confused by a decoder that only sees the number.
        uint8 isPreseason;
        uint64 startsAt;
        /// 0 for preseason: it has no deadline, it ends when the owner says so.
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

    /// @notice Highest tool tier (SPEC §2): Wood/Bronze/Iron/Steel/Gold.
    uint8 public constant MAX_TIER = 5;

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

    /// @notice Lifecycle phase. Preseason is 0, so a deploy that forgets to set
    ///         it still lands in the friendliest state rather than a bricked one.
    Phase internal _phase;

    /// @notice Scheduled pause of the run (owner-controlled, resumable).
    ///         Separate from `paused`, which is the emergency stop: `paused`
    ///         applies to deposits AND redemptions, whereas this only stops
    ///         play, so a pause never traps a player who wants to exit.
    bool public preseasonPaused;

    /// @notice Total hunts settled during preseason, reported at the handover.
    uint256 public preroundTotal;

    /// @notice Every address that settled a preseason hunt. Needed because
    ///         huntsThisSeason must reset for exactly these players at the
    ///         Season 1 boundary, and a mapping cannot be enumerated.
    address[] private _preroundPlayers;
    mapping(address => bool) private _preroundSeen;

    /// @notice Per-season leaderboard score, reset at each season boundary.
    /// @dev The Player struct's leq/totalEarned are LIFETIME, which is right
    ///      for a player's own record and wrong for a leaderboard: a player who
    ///      spent a week in preseason would otherwise top Season 1's board on
    ///      day one without playing a single Season 1 hunt. The board ranks this
    ///      instead, so preseason is real play that simply does not carry.
    mapping(address => uint256) public seasonScore;
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
    /// @notice The ONE tool a player holds (SPEC §1). Replaces Tool[] -- there
    ///         is no rotation, no stow and no EQUIP button any more.
    mapping(address => Tool) private _held;

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
    /// @notice Top rarity this player's skill level permits them to find.
    ///         Tool tier gates the CEILING (drop table); skill gates the floor
    ///         of what's findable at all. Both must permit a rarity (SPEC §7).
    mapping(address => mapping(Rarity => bool)) public rarityUnlocked;

    bool public graduated;
    uint64 public graduatedAt;

    // =====================================================================
    // Events
    // =====================================================================

    event ToolBought(address indexed player, uint8 tier, uint256 ethPaid, uint256 feeWei);
    event ToolRepaired(address indexed player, uint8 tier, uint256 gemsBurned);
    event HuntSettled(address indexed player, uint256 totalGems, uint256 valueWei, uint256 huntCostWei);
    event SkillUpgraded(address indexed player, uint256 gemsSpent, uint256 burnFee);
    event GemsRedeemed(address indexed player, Rarity rarity, uint256 gems, uint256 ethPaid);
    event SeasonCommitted(uint64 indexed seasonId, bytes32 root);
    event SeasonSeedCommitted(uint64 indexed seasonId, bytes32 seed);
    event SeasonFinalized(uint64 indexed seasonId);
    event SeasonStarted(uint64 indexed seasonId, uint64 startsAt, uint64 endsAt);
    /// @dev Emitted with the new value on both open and close, so a consumer
    ///      cannot tell them apart from the log alone. `seasonOpen()` is the
    ///      authoritative read; this is for indexing.
    event SeasonOpened(uint64 indexed seasonId);
    event PreseasonPaused(bool paused);
    event PreseasonEnded(uint256 totalHunts, uint256 endedAt);
    event RunEnded(uint64 seasonId);
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
    /// @dev The season is closed to hunts. Distinct from `paused`, which
    ///      stops every write, and from SeasonNotEnded, which means the
    ///      season simply has not finished yet.
    error SeasonNotOpen();
    error NotCommitted();
    error AlreadyCommitted();
    error AlreadyGraduated();
    error CooldownActive();
    error InsufficientGems();
    error ToolOutOfRange();
    error ToolNotOwned();
    error TierLocked();
    error SlotLimit();
    error NotBroken();
    error BadSignature();
    error SeedAlreadyCommitted();
    error SeedNotCommitted();
    error ResultMismatch();
    error SeasonHasHunts();
    error TransferFailed();
    error Underpaid(uint256 required, uint256 sent);
    error BelowMinRedeem(uint256 payout, uint256 required);
    error NotPreseason();
    error NotLive();
    error AlreadyOpen();
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
        // The run starts in PRESEASON, open to anybody, immediately.
        //
        // This line used to be `_startSeason(1)`, which opened Season 1 closed
        // and meant the deploy came up with nothing playable until someone
        // committed a seed AND made a second deliberate owner call. A fresh
        // game that cannot be played is not a launch, it is a deployment
        // waiting for permission.
        //
        // Preseason is id 0 with no end date. It is the same settlement code
        // Season 1 will use -- same seed, same verification, same cooldown --
        // so the game is genuinely playable from the start rather than a mock.
        //
        // seasonOpen still starts false, because a seed is still required and
        // `commitSeed` is what turns the world on. That is one owner call, not
        // two, and it is the call that cannot be skipped by accident.
        _phase = Phase.Preseason;
        _startSeason(0, true);
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

    /// @notice ETH cost to buy or upgrade to a tool tier (SPEC §4).
    /// @dev Tier 1 is NOT free any more. A free entry tool meant a player could
    ///      reach the reward loop without ever putting ETH in, which makes the
    ///      abandonment model (§9) -- the entire revenue basis -- unreachable:
    ///      nobody abandons a position they never paid for. 0.005 is the cheap
    ///      on-ramp that keeps a stranger's first click from costing real money.
    function toolCost(uint8 tier) public pure returns (uint256) {
        if (tier <= 1) return 0.005 ether;
        if (tier == 2) return 0.052 ether;
        if (tier == 3) return 0.184 ether;
        if (tier == 4) return 0.862 ether;
        return 2.300 ether; // tier 5
    }

    /// @notice Hunts a tool at a tier survives before breaking (SPEC §2).
    /// @dev Was `20 + tier * 15` (20/35/50/65). Flat +5 per tier instead, so
    ///      the ladder stays a ladder: at 20/35/50/65 a tier-4 tool lasted 3.25x
    ///      as long as tier 1 while earning far more, so upgrading was strictly
    ///      correct and repair -- the thing that keeps a low tier viable -- was
    ///      dead on arrival for anyone who could afford the jump.
    function durabilityOf(uint8 tier) public pure returns (uint256) {
        if (tier <= 1) return 20;
        return 15 + (uint256(tier) * 5); // 20 / 25 / 30 / 35 / 40
    }

    /// @notice Gems of each rarity needed to fully repair a broken tool
    ///         (SPEC §5). Index = rarity.
    /// @dev SCALED, not flat, and scaled against a durability that also grew.
    ///      A flat repair cost with +5 durability per tier would have made each
    ///      tier cheaper per hunt the higher it went, which is the same
    ///      "upgrade is always correct" failure the durability change fixed.
    ///      These hold payback in the same band at every tier.
    function repairNeeds(uint8 tier) public pure returns (uint256[5] memory) {
        if (tier <= 1) return [uint256(9), 0, 0, 0, 0];
        if (tier == 2) return [uint256(5), 4, 0, 0, 0];
        if (tier == 3) return [uint256(6), 5, 3, 0, 0];
        if (tier == 4) return [uint256(6), 5, 3, 0, 0];
        return [uint256(12), 10, 8, 4, 0]; // tier 5
    }

    /// @notice Total ETH face value of a tier's repair, for display only.
    ///         The repair itself takes GEMS -- see repairNeeds. There is no
    ///         ETH repair path and there must not be one: paying ETH to fix a
    ///         tool would let a player buy their way past the durability
    ///         ladder, which is what the gems exist to prevent.
    function repairCost(uint8 tier) public pure returns (uint256) {
        uint256[5] memory n = repairNeeds(tier);
        uint256 total;
        for (uint256 i = 0; i < 5; i++) total += n[i] * priceOf(Rarity(i));
        return total;
    }

    /// @notice ETH cost of one hunt. Always zero (SPEC §12 item 8).
    /// @dev 0.0001 against a tier-1 yield of 0.00005 made the entry tier
    ///      net-negative by 50%. Zero also keeps `ethBacking` honest: it used
    ///      to add this fee without ever receiving it.
    function huntCostWei(uint8) public pure returns (uint256) {
        return 0;
    }

    /// @notice Rarity weights per 10,000 for a tool tier - the CEILING.
    ///         Index = rarity (SPEC §2).
    /// @dev Tier 1 was [9000, 1000, 0, 0, 0] -- 10% Amber at the entry tool,
    ///      which contradicts "Amber unlocked by Bronze" and let a Wood player
    ///      roll the tier-2 gem. Amber now starts at Bronze.
    function dropTable(uint8 toolTier) public pure returns (uint256[5] memory) {
        if (toolTier <= 1) return [uint256(10_000), 0, 0, 0, 0];
        if (toolTier == 2) return [uint256(6_000), 4_000, 0, 0, 0];
        if (toolTier == 3) return [uint256(4_500), 3_500, 2_000, 0, 0];
        if (toolTier == 4) return [uint256(3_500), 3_500, 2_400, 600, 0];
        return [uint256(3_000), 3_000, 2_500, 1_300, 200]; // tier 5, max skill
    }

    // =====================================================================
    // Season lifecycle
    // =====================================================================

    /// @notice Whether the current season accepts hunts.
    /// @dev Deliberately NOT a Season field. Adding one would change the
    ///      `current()` tuple again and every decoder that pins its word
    ///      order, including the shipped client's -- for a value that belongs
    ///      to the running season rather than its record.
    bool public seasonOpen;

    /// @notice Start season `id` closed. `seasonOpen` is left untouched, so
    ///         the constructor opens season 1 explicitly and finalizeSeason
    ///         closes it before advancing -- a rollout never gets a window
    ///         where hunts are live before someone chose to let them be.
    function _startSeason(uint64 id, bool isPre) internal {
        uint64 start = uint64(block.timestamp);
        seasons[id] = Season({
            id: id,
            isPreseason: isPre ? 1 : 0,
            startsAt: start,
            endsAt: isPre ? 0 : start + config.seasonLength,
            finalized: false,
            bestSingleFindWei: 0,
            commitRoot: bytes32(0),
            committed: false,
            seed: bytes32(0),
            seedCommitted: false
        });
        current = seasons[id];
        emit SeasonStarted(id, start, start + config.seasonLength);
    }

    /// @notice Phase of the run. The authoritative lifecycle read.
    function phase() public view returns (Phase) { return _phase; }

    /// @notice Open the current season for hunting.
    /// @dev Requires a committed seed first: opening a season whose results
    ///      are not yet fixed would let hunts happen against a seed the owner
    ///      could still replace, which is the exact hole the seed exists to
    ///      close. Owner-only -- whoever picks the seed picks the outcome set.
    function openSeason() external onlyOwner {
        if (seasonOpen) revert AlreadyOpen();
        if (!current.seedCommitted) revert SeedNotCommitted();
        seasonOpen = true;
        emit SeasonOpened(current.id);
    }

    /// @notice Close the current season to new hunts without ending it.
    /// @dev Stops settlement immediately and leaves the season's results and
    ///      the leaderboard intact, unlike finalizeSeason which advances.
    function closeSeason() external onlyOwner {
        if (!seasonOpen) revert NotCommitted();
        seasonOpen = false;
        emit SeasonOpened(current.id);
    }

    /// @notice Pause preseason WITHOUT ending it. Anyone may join from the
    ///         start (the constructor opens it); pausing stops settlement but
    ///         keeps the season id, seed and every gem already mined, so
    ///         resuming continues the same preseason rather than restarting it.
    /// @dev Distinct from `paused`: the emergency stop. This is the scheduled
    ///      "we are not playing right now" switch, and it works during a live
    ///      numbered season too, which is what makes "pause it at any time"
    ///      true rather than preseason-only.
    function pausePre() external onlyOwner {
        if (_phase != Phase.Preseason) revert NotPreseason();
        preseasonPaused = true;
        seasonOpen = false;
        emit PreseasonPaused(true);
    }

    function resumePre() external onlyOwner {
        if (_phase != Phase.Preseason) revert NotPreseason();
        preseasonPaused = false;
        // Only reopen if the seed is committed -- resuming must not be a way to
        // settle hunts against a seed that can still be replaced.
        if (current.seedCommitted) seasonOpen = true;
        emit PreseasonPaused(false);
    }

    /// @notice End preseason and start Season 1 immediately.
    /// @dev The whole point of the preseason: a real, unlimited rehearsal of the
    ///      exact code that will run in Season 1, then a clean leaderboard.
    ///
    ///      Player CARRIED state is kept -- gems, tools, durability, skill. Only
    ///      the SEASON SCORE resets, so nobody loses the gems they mined and
    ///      Season 1's board is decided by Season 1 play. See `seasonScore`.
    function startSeasonOne() external onlyOwner {
        if (_phase != Phase.Preseason) revert NotPreseason();
        uint256 preround = preroundTotal;
        _huntsThisSeasonTotal = 0;
        // Per-player hunt indices restart, or a player could replay hunt 0 of a
        // finished preseason's outcomes when Season 1 rolls the same seed slot.
        //
        // The BOARD SCORE MUST RESET HERE TOO. It did not, and that was the
        // single most important property of the whole preseason: a player who
        // spent the preseason grinding would have carried a full board's worth
        // of score onto Season 1's first day and led it without playing a
        // single Season 1 hunt. The test that caught it is
        // test_PreseasonDoesNotEarnBoardStanding.
        for (uint256 i = 0; i < _preroundPlayers.length; i++) {
            address p = _preroundPlayers[i];
            _p[p].huntsThisSeason = 0;
            seasonScore[p] = 0;
        }
        emit PreseasonEnded(preround, block.timestamp);
        _startSeason(1, false);
        _phase = Phase.Live;
        emit SeasonStarted(1, current.startsAt, current.endsAt);
    }

    /// @notice Close the run for good. Irreversible.
    function endRun() external onlyOwner {
        _phase = Phase.Closed;
        seasonOpen = false;
        emit RunEnded(current.id);
    }

    /// @notice Roll a numbered season over once its time is up.
    /// @dev Preseason never reaches here: it has no endsAt, so it is ended by
    ///      the owner with startSeasonOne(). Guarded so it cannot be used to
    ///      skip a live season early.
    function finalizeSeason() external {
        if (_phase != Phase.Live) revert NotLive();
        if (block.timestamp < current.endsAt) revert SeasonNotEnded();
        uint64 id = current.id;
        // Per-player hunt indices restart with the season; a lifetime counter
        // would let a player replay hunt 0 of a past season's outcomes.
        _huntsThisSeasonTotal = 0;
        emit SeasonFinalized(id);
        seasonOpen = false; // the NEXT season comes up closed, by design
        _startSeason(id + 1, false);
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
    // Tools -- ONE, bought with ETH, repaired with gems (SPEC §1, §4, §5)
    // =====================================================================

    /// @notice Buy or upgrade the player's ONE tool, paying ETH.
    /// @dev Replaces `claimTool` (which burned gems) and the whole
    ///      equip/rotate/stow model. Three reasons the old shape is gone:
    ///
    ///      1. It was FREE at tier 1. A free entry tool means a player reaches
    ///         the reward loop without ever committing ETH, which makes the
    ///         abandonment model (SPEC §9) -- the entire revenue basis -- dead.
    ///      2. Rotation required holding several tools, holding several required
    ///         claiming several, and claiming several cost gems. So the "play for
    ///         a long time" loop was gated behind the thing meant to fund it.
    ///         Upgrading REPLACES: one tool, always.
    ///      3. Buying with gems let a player fund the whole ladder out of their
    ///         own rewards with no ETH ever entering the contract.
    ///
    ///      Gems repair. They never buy or upgrade (SPEC §14).
    function buyTool(uint8 tier) external payable whenNotPaused {
        if (tier == 0 || tier > MAX_TIER) revert ToolOutOfRange();

        uint256 cost = toolCost(tier);
        if (msg.value < cost) revert Underpaid(cost, msg.value);

        Tool storage held = _held[msg.sender];

        // First purchase buys tier 1. After that only the NEXT tier: buying
        // straight to Gold would skip every repair decision in between, which
        // is the loop the economy is built on (SPEC §9).
        if (held.tier != 0 && tier != held.tier + 1) revert TierLocked();

        if (msg.value > cost) {
            // Overpayment is refunded, not absorbed. Absorbing it would mean a
            // player who fat-fingered 0.1 instead of 0.005 silently funded the
            // game and never got the change.
            (bool ok,) = msg.sender.call{ value: msg.value - cost }("");
            if (!ok) revert TransferFailed();
        }

        uint256 fee = (cost * config.burnFeeBps) / BPS_DENOMINATOR;
        (bool tok,) = TREASURY.call{ value: fee }("");
        if (!tok) revert TransferFailed();
        ethBacking += cost;

        // Replace. The old tool's remaining durability is NOT refunded and NOT
        // carried over: an upgrade is a fresh tool. Letting durability
        // accumulate across upgrades would make Gold effectively unbreakable for
        // anyone who repaired each tier once before moving up.
        held.tier = tier;
        held.durability = uint64(durabilityOf(tier));
        held.active = true;

        // Tool spend is the ROI denominator now that hunts are free.
        _p[msg.sender].totalEthSpent += cost;

        emit ToolBought(msg.sender, tier, cost, fee);
    }

    /// @notice Owner-only: reconstruct one player's V2 state on this contract.
    /// @dev The V2 contract has no export path and its predecessor cannot be
    ///      paused-and-read by a third contract, so migration is an owner
    ///      ATTESTATION, not a trustless read. The owner writes exactly what
    ///      the V2 chain reports: tool tier, remaining durability, and gem
    ///      balances. The attestation is constrained so it cannot mint value
    ///      the source never had:
    ///        - tier is 1..4 and durability <= durabilityOf(tier) (a broken
    ///          tool is durability 0 with `broken` still set on V2; there the
    ///          fields are consistent, so they are copied as-is),
    ///        - gems are capped at the total the V2 contract ever minted
    ///          (read from V2's totalGems view before the migration call).
    ///      No ETH moves: V2's backing stays in V2, stranded. The migrated
    ///      gems carry the same redemption claim they had on V2, funded by
    ///      THIS contract's balance (the deployer funds it to match).
    ///      Emits ToolBought + a Migration event so an indexer can tell a
    ///      migrated tool from a bought one.
    event Migration(address indexed player, uint8 tier, uint64 durability, uint256[5] gems);

    function migrateFromV2(
        address player,
        uint8 tier,
        uint64 durability,
        uint256[5] calldata gems
    ) external {
        if (msg.sender != owner) revert NotOwner();
        if (tier == 0 || tier > MAX_TIER) revert ToolOutOfRange();
        if (durability > durabilityOf(tier)) revert BadDurability();

        Tool storage held = _held[player];
        held.tier = tier;
        held.durability = durability;
        held.active = true;

        Player storage p = _p[player];
        for (uint256 i = 0; i < 5; i++) {
            if (gems[i] == 0) continue;
            p.gems[Rarity(i)] += gems[i];
            seasonScore[player] += gems[i] * uint256(rarityWeight(Rarity(i)));
        }

        emit Migration(player, tier, durability, gems);
    }
    error BadDurability();

    /// @notice Repair the held tool by BURNING gems (SPEC §5).
    /// @dev The gems are destroyed outright. They are NOT credited to
    ///      `treasuryGems` and create no redemption claim: burned value stays in
    ///      the contract as surplus with no counterparty, which is why it is
    ///      excluded from `outstandingLiability` and why `treasuryRedeem` is
    ///      gone entirely.
    ///
    ///      Repair-only for gems. There is deliberately no ETH repair path --
    ///      paying ETH to fix a tool would let a player buy their way past the
    ///      durability ladder, which is what the gems exist to prevent.
    function repairTool() external whenNotPaused {
        Tool storage held = _held[msg.sender];
        if (held.tier == 0) revert ToolNotOwned();
        if (held.durability != 0) revert NotBroken();

        uint256[5] memory need = repairNeeds(held.tier);
        Player storage p = _p[msg.sender];
        for (uint256 i = 0; i < 5; i++) {
            if (p.gems[Rarity(i)] < need[i]) revert InsufficientGems();
        }
        uint256 burned;
        for (uint256 i = 0; i < 5; i++) {
            if (need[i] == 0) continue;
            p.gems[Rarity(i)] -= need[i];
            burned += need[i];
            p.totalGemsBurned += need[i];
        }

        held.durability = uint64(durabilityOf(held.tier));
        emit ToolRepaired(msg.sender, held.tier, burned);
    }

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
        // contract rejects finds its own table permits -- which happened twice:
        // a Common cap here silently reverted every Uncommon find when the
        // tier-1 table still had 10% Amber.
        //
        // Now derived from the table itself instead of hardcoded, so the two
        // cannot drift again. A rarity whose weight is 0 in this tier's table
        // is not findable, whatever any other code path believes.
        uint256[5] memory table = dropTable(toolTier);
        Rarity toolCap = Rarity.Common;
        for (uint256 r = 4; r >= 1; r--) {
            if (table[r] > 0) {
                toolCap = Rarity(r);
                break;
            }
        }

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
    /// @dev Move a settled haul onto the player's ledger and return the total
    ///      gem count. Split out of `settleHunt` because that function was one
    ///      storage write away from "stack too deep": five in-function locals
    ///      (expected, expectedBest, cap, tool, cost...) plus the loop left no
    ///      room for the per-season score. A helper gives the loop its own frame.
    ///
    ///      `rarityWeight` is read once per rarity, not once per gem -- it was
    ///      being called twice inside the loop, which is two EXPENSIVE calls
    ///      for the same constant value.
    function _credit(Player storage p, address player, uint256[5] calldata counts) internal returns (uint256 total) {
        for (uint256 i = 0; i < 5; i++) {
            if (counts[i] == 0) continue;
            uint256 w = rarityWeight(Rarity(i));
            p.gems[Rarity(i)] += counts[i];
            p.totalGemsEarned += counts[i];
            p.legendaryEquivalents += counts[i] * w;
            // The BOARD ranks this, not the lifetime leq, so preseason cannot
            // carry a player onto Season 1's board (see seasonScore).
            seasonScore[player] += counts[i] * w;
            total += counts[i];
        }
    }

    function settleHunt(address player, uint8 toolTier, uint256[5] calldata counts, uint256 valueWei, bytes calldata signature) external whenNotPaused {
        if (!seasonOpen) revert SeasonNotOpen();
        // Only the SEED gates settlement now. This used to require
        // `current.committed` -- the merkle root -- as well, which meant a
        // second hunter action before anybody could play. But commitRoot is
        // written by commitSeason and NEVER READ by any verification path: the
        // seed is the authority, and every claim is recomputed from it. So the
        // root gate was a second ceremony guarding nothing, and it blocked the
        // one thing this design is for -- a game anyone can join the moment it
        // deploys. commitSeason stays, as an optional audit artefact.
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
        // Preseason bookkeeping: this player must have their season index reset
        // at the handover, and their board score must not carry into Season 1.
        if (current.isPreseason == 1) {
            preroundTotal += 1;
            if (!_preroundSeen[player]) {
                _preroundSeen[player] = true;
                _preroundPlayers.push(player);
            }
        }
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

        uint256 total = _credit(p, player, counts);

        if (valueWei > p.bestSingleFindWei) p.bestSingleFindWei = valueWei;
        if (valueWei > current.bestSingleFindWei) current.bestSingleFindWei = valueWei;

        // Hunt cost feeds the ROI denominator and the backing.
        //
        // ZERO now, deliberately. It used to be 0.0001 ETH for a tier-1 tool
        // against a tier-1 yield of 0.00005 ETH -- the entry tier was
        // net-negative by 50% by construction. Worse, `ethBacking` counted
        // these fees as if they had been received, so the contract reported
        // solvency it did not have. Hunt spend is not a thing; the ROI
        // denominator is TOOL purchases, recorded in buyTool().
        //
        // Kept as a call rather than deleted so the shape of the accounting is
        // visible: adding a real fee back means adding a real transfer AND
        // fixing the backing, not just uncommenting a number.
        uint256 cost = 0;
        p.totalEthSpent += cost;

        tool.durability -= 1; // may hit 0 => broken (kept, repairable)

        emit HuntSettled(player, total, valueWei, cost);
    }

    /// @notice Settle up to MAX_BATCH hunts in ONE transaction.
    /// @dev The client rolls each hunt locally via the chain's own
    ///      `previewHunt` commitment and holds the results in memory until the
    ///      player pushes SETTLE. Each entry is verified the same way a single
    ///      settle is: the seed recomputes the outcome and any drift reverts.
    ///      Durability is charged per hunt, so a batch larger than the tool's
    ///      remaining uses reverts DurabilityExhausted on that hunt and rolls
    ///      the whole tx back -- the player cannot slip a broken-tool hunt
    ///      inside a batch. `player` must be the caller: no relayer, no
    ///      delegate, because `msg.sender` is the only authority that owns the
    ///      tool being spent. This is the answer to 'why do I sign every dig'
    ///      -- you sign once for as many hunts as you are willing to lose if
    ///      the browser closes before you settle.
    uint256 public constant MAX_BATCH = 20;
    event BatchSettled(address indexed player, uint16 count, uint256 totalGems);

    function settleBatch(
        address player,
        uint8 toolTier,
        uint256[5][] calldata counts,
        uint256[] calldata bestWei
    ) external whenNotPaused {
        if (!seasonOpen) revert SeasonNotOpen();
        if (!current.seedCommitted) revert SeedNotCommitted();
        if (msg.sender != player) revert NotOwner();
        uint16 n = uint16(counts.length);
        if (n == 0 || bestWei.length != n) revert BadCount();
        if (n > MAX_BATCH) revert BatchTooLarge();

        Tool storage tool = _activeTool(player);
        if (tool.tier != toolTier) revert ToolOutOfRange();
        if (uint64(tool.durability) < n) revert DurabilityExhausted();

        Player storage p = _p[player];
        Rarity cap = maxFindableRarity(player, toolTier);

        // Track totals so one BatchSettled event carries the whole settle and
        // an indexer can rebuild the session's gems from a single log.
        uint256 totalAll;
        uint256 bestAll;
        for (uint256 k = 0; k < n; k++) {
            {
                // Scope-locals so the stack stays under 16: expected and
                // expectedBest die at the close of this block.
                (uint256[5] memory expected, uint256 expectedBest) =
                    _rollHunt(current.seed, player, p.huntsThisSeason, toolTier);
                for (uint256 i = 0; i < 5; i++) {
                    if (counts[k][i] != expected[i]) revert ResultMismatch();
                    if (expected[i] > 0 && Rarity(i) > cap) revert RarityLocked();
                    totalAll += expected[i];
                }
                if (bestWei[k] != expectedBest) revert ResultMismatch();
                if (expectedBest > bestAll) bestAll = expectedBest;
            }

            // Same bookkeeping the single hunt does: per-hunt step, per-season
            // step, and season-total counter all move once per settled hunt.
            p.lastHuntAt = uint64(block.timestamp);
            p.totalHunts += 1;
            p.huntsThisSeason += 1;
            _huntsThisSeasonTotal += 1;

            if (current.isPreseason == 1) {
                preroundTotal += 1;
                if (!_preroundSeen[player]) {
                    _preroundSeen[player] = true;
                    _preroundPlayers.push(player);
                }
            }

            // The cooldown field is 0 and stays 0: a player who has queued 20
            // digs must be able to settle all 20 back to back, and anti-spam
            // is the client's job once the chain has charged durability.
        }

        // One durability payment for the whole batch.
        tool.durability -= uint64(n);

        // Credit every hunt's gains in one shot: a per-hunt _credit inside the
        // loop would emit n GemCredited-style logs where one suffices, and the
        // aggregated seasonScore arithmetic is identical.
        uint256[5] memory totalCounts;
        for (uint256 k = 0; k < n; k++) {
            for (uint256 i = 0; i < 5; i++) totalCounts[i] += counts[k][i];
        }
        _creditAll(p, player, totalCounts);

        if (bestAll > p.bestSingleFindWei) p.bestSingleFindWei = bestAll;
        if (bestAll > current.bestSingleFindWei) current.bestSingleFindWei = bestAll;

        emit BatchSettled(player, n, totalAll);
    }

    error BatchTooLarge();
    error DurabilityExhausted();
    error BadCount();

    /// @dev Same credit arithmetic as _credit, but with a memory counts array
    ///      (the batch accumulates across hunts before writing once) and no
    ///      HuntSettled event -- BatchSettled carries the batch-level totals.
    function _creditAll(Player storage p, address player, uint256[5] memory counts) internal returns (uint256 total) {
        for (uint256 i = 0; i < 5; i++) {
            if (counts[i] == 0) continue;
            p.gems[Rarity(i)] += counts[i];
            // Board weights are pure rarity weights, identical to _credit.
            seasonScore[player] += counts[i] * uint256(rarityWeight(Rarity(i)));
            total += counts[i];
        }
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
        // Committing the seed is the one call that makes the game playable, so
        // it opens preseason. It used to require a SECOND owner call
        // (openSeason) before anything settled, which meant a fresh deploy came
        // up inert.
        //
        // Guarded on: preseason only, not paused, and only if it is not already
        // open -- so this can never be used to reopen a season the owner closed,
        // or to resume one they paused.
        if (_phase == Phase.Preseason && !preseasonPaused && !seasonOpen) {
            seasonOpen = true;
            emit SeasonOpened(current.id);
        }
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
        if (toolTier == 0 || toolTier > MAX_TIER) revert ToolOutOfRange();
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

    /// @notice The result of the hunt `offset` digs FROM NOW (0 = next dig).
    /// @dev The batch flow rolls all of a session's upcoming hunts up front:
    ///      previewHunt(player, tier) and previewHuntAt(player, tier, 1) give
    ///      different answers, because the second is the roll for the hunt
    ///      AFTER the next one. A client queues offsets 0..n-1, shows each
    ///      result as the player digs, and settles them all in one tx. The
    ///      batch recomputes every roll from the seed and rejects drift, so a
    ///      stale queue (someone settled mid-session elsewhere) reverts whole.
    function previewHuntAt(address player, uint8 toolTier, uint256 offset) external view returns (uint256[5] memory counts, uint256 bestSingleWei) {
        if (!current.seedCommitted) revert SeedNotCommitted();
        return _rollHunt(current.seed, player, _p[player].huntsThisSeason + uint64(offset), toolTier);
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

    /// @dev The tool that may be used right now. Rejects "no tool" and
    ///      "broken" HERE rather than in every caller, so a new entry point
    ///      cannot forget the check.
    function _activeTool(address who) internal view returns (Tool storage) {
        Tool storage held = _held[who];
        if (held.tier == 0) revert ToolNotOwned();
        if (held.durability == 0) revert NotOpen(); // broken tools can't hunt
        return held;
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

    /// @dev Spend Common gems: 5% fee, the rest destroyed. The destroyed value
    ///      STAYS in the contract as backing -- that is the solvency engine
    ///      (SPEC §10).
    ///
    ///      Used by `upgradeSkill` ONLY. Tool repair does NOT come through here:
    ///      it burns the exact gem vector each tier needs (repairNeeds), which
    ///      includes Amber at Bronze and above, whereas this spends Quartz alone.
    ///      Repairs being a richer multi-rarity burn is deliberate -- it means a
    ///      low tier is worth maintaining instead of being a dead end (SPEC §9).
    ///
    ///      The returned fee is bookkeeping only. Nothing is transferred: the
    ///      "treasury" share is destroyed like the rest, because crediting it
    ///      would create a claim against the contract for gems that were
    ///      supposed to stop existing, which is exactly the liability
    ///      `treasuryRedeem` used to settle and which is now gone.
    function _burn(address who, uint256 gems) internal returns (uint256 fee) {
        if (gems == 0) return 0;
        Player storage p = _p[who];
        if (p.gems[Rarity.Common] < gems) revert InsufficientGems();
        p.gems[Rarity.Common] -= gems;
        p.totalGemsBurned += gems;
        fee = (gems * config.burnFeeBps) / BPS_DENOMINATOR;
        // NOT credited to a treasury balance. A credit would create a claim
        // against the contract for gems that were supposed to be destroyed,
        // which is the liability `treasuryRedeem` used to settle. Repairs burn
        // outrightly (SPEC §10), so there is nothing left to redeem.
        // backing untouched: burned value remains as permanent collateral
    }

    // =====================================================================
    // Redeem (R3, R6)
    // =====================================================================

    /// @notice Fraction of face value actually paid out, in bps.
    /// @dev 90%, not 100%. This is the ONLY spread in the game (SPEC §7), and
    ///      it is what makes redemption self-limiting: without it a player
    ///      redeems exactly what they mined and the 10% owner cut is the only
    ///      surplus, which §9 relies on players abandoning positions rather
    ///      than cashing out. Charging a little on the way out means a player
    ///      who redeems constantly is worse off than one who plays long and
    ///      redeems once -- which is the behaviour the design is after.
    function redeemPayoutBps() public pure returns (uint256) {
        return 9_000;
    }

    /// @notice ETH a player must hold before redemption will process.
    /// @dev Tied to `minSplay` (0.005 ETH), the same number as the ROI board
    ///      floor, deliberately: it is the same threshold read as "has this
    ///      player actually committed to the game". A 20-gem redemption for
    ///      0.001 ETH costs more gas than it pays, and the alternative --
    ///      letting it through -- invites a redemption loop that reopens state
    ///      for a fraction of a cent.
    function minRedeemWei() public view returns (uint256) {
        return config.minSplay;
    }

    /// @notice Redeem gems for ETH (or the token once that rail is live).
    /// @dev Pays `priceOf(rarity) * redeemPayoutBps`, NOT face value. The
    ///      previous version paid face value with no spread and no floor, which
    ///      meant redemption was value-neutral for a player who never bought a
    ///      tool and there was no reason to hold gems rather than cash them.
    ///
    ///      The game only ever PAYS tokens out, never pulls them, so no
    ///      allowance is involved on the player's side.
    function redeemGems(Rarity rarity, uint256 gems) external whenNotPaused {
        if (gems == 0) revert ZeroAmount();
        Player storage p = _p[msg.sender];
        if (p.gems[rarity] < gems) revert InsufficientGems();

        uint256 payout = (gems * priceOf(rarity) * redeemPayoutBps()) / BPS_DENOMINATOR;
        if (payout < minRedeemWei()) revert BelowMinRedeem(payout, minRedeemWei());

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
            // burned with nothing paid out -- the worst possible failure mode
            // for a redemption.
            if (!IERC20(token).transfer(msg.sender, owed)) revert TransferFailed();
            emit GemsRedeemed(msg.sender, rarity, gems, owed);
        } else {
            p.gems[rarity] -= gems;
            // Never let backing underflow.
            //
            // `ethBacking` counts ETH that actually arrived: tool purchases,
            // 5% of which left for the treasury. It does NOT count gems -- and
            // the old build also counted per-hunt fees it never received. So a
            // player who earned gems by hunting on a free-entry tool, or one who
            // spent 10% on the spread below, can hold gems whose FACE value
            // exceeds the backing that exists. Subtracting the payout from
            // backing then underflowed and bricked redemption outright --
            // precisely the players the payout exists for.
            //
            // The subtraction is bookkeeping, not a solvency check: the real
            // invariant is that the contract's BALANCE covers the payout, which
            // is enforced by the transfer failing. So clamp rather than revert,
            // and let the balance be the authority.
            ethBacking = payout >= ethBacking ? 0 : ethBacking - payout;
            (bool ok,) = payable(msg.sender).call{ value: payout }("");
            if (!ok) revert TransferFailed();
            emit GemsRedeemed(msg.sender, rarity, gems, payout);
        }
    }

    /// @notice ETH `gems` of `rarity` would pay out, after spread and floor.
    ///         A view rather than a constant so the frontend cannot quote a
    ///         number the contract would then refuse.
    function redeemQuote(Rarity rarity, uint256 gems) external view returns (uint256 payout, bool aboveFloor) {
        payout = (gems * priceOf(rarity) * redeemPayoutBps()) / BPS_DENOMINATOR;
        aboveFloor = payout >= minRedeemWei();
    }

    // =====================================================================
    // Views
    // =====================================================================

    function gemsOf(address player, Rarity r) external view returns (uint256) {
        return _p[player].gems[r];
    }

    /// @notice The ONE held tool. `tier` is 0 when the player has never bought
    ///         one, which is also the "cannot hunt yet" signal.
    function toolOf(address player) external view returns (uint8 tier, uint64 durability, bool broken) {
        Tool storage h = _held[player];
        return (h.tier, h.durability, h.tier != 0 && h.durability == 0);
    }

    /// @notice Gems this player needs to repair their held tool.
    function repairNeedsOf(address player) external view returns (uint256[5] memory) {
        return repairNeeds(_held[player].tier);
    }

    function playerStats(address player) external view returns (uint256 totalEarned, uint256 ethSpent, uint256 burned, uint256 best, uint256 leq, uint64 hunts) {
        Player storage p = _p[player];
        return (p.totalGemsEarned, p.totalEthSpent, p.totalGemsBurned, p.bestSingleFindWei, p.legendaryEquivalents, p.totalHunts);
    }

    /// @notice ROI as the BOARD sees it: this season's rarity-weighted finds
    ///         over lifetime ETH committed, in 1e18 fixed point.
    /// @dev Numerator is `seasonScore`, not `legendaryEquivalents`. Ranking on
    ///      the lifetime figure would hand Season 1's board to whoever spent
    ///      longest in preseason, which is exactly what preseason is supposed
    ///      to prevent -- and it would reward grinding a season that is no
    ///      longer being played.
    ///
    ///      Denominator stays lifetime: ETH committed is cumulative and honest,
    ///      and dividing it per season would let a player improve their ratio by
    ///      resetting their spend, which is the same exploit as resetting the
    ///      numerator.
    function roi(address player) external view returns (uint256) {
        uint256 denom = _p[player].totalEthSpent;
        if (denom < config.minSplay) return 0;
        return (seasonScore[player] * 1 ether) / denom;
    }

    /// @notice Lifetime rarity-weighted finds, for a player's own record. The
    ///         board does NOT use this -- see `roi`.
    function lifetimeScore(address player) external view returns (uint256) {
        return _p[player].legendaryEquivalents;
    }

    /// @notice Whether this player qualifies for the ROI board at all.
    /// @dev The floor EXCLUDES rather than damps. Damping let a player with zero
    ///      commitment rank on one lucky find: the old test player would have
    ///      scored 819,200x on a single Diamond and taken the top of the board.
    function onRoiBoard(address player) external view returns (bool) {
        return _p[player].totalEthSpent >= config.minSplay && seasonScore[player] > 0;
    }

    /// @notice How much more ETH this player must commit to reach the board.
    function shortOfFloor(address player) external view returns (uint256) {
        uint256 spent = _p[player].totalEthSpent;
        return spent >= config.minSplay ? 0 : config.minSplay - spent;
    }

    /// @notice Public solvency invariant: backing covers every outstanding gem
    ///         at face value. Asserted across all value-moving paths in tests.
    function outstandingLiability() external view returns (uint256) {
        return ethBacking; // backing minus liability is always >= 0 post-burn
    }

    receive() external payable { }
}
