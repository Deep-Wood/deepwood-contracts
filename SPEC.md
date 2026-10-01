# DeepWood — Game Specification

**Status:** design draft. Nothing deployed. No token created. Onchain launch
requires explicit approval.

**Ticker:** `$DEEPWOOD` (collision-checked clear; `$DEEP` is taken by DeepBook
on Sui, `$DWOOD` is an acceptable fallback)

---

## 1. The one-paragraph version

Players hunt gems in a virtual jungle. Hunting runs off-chain because it must
feel like a web2 game; settlement runs on-chain because value must be real. Gems
are denominated and priced in ETH, so the economy needs no price oracle. Tools
have durability and break rather than vanish. A season ends, and the leaderboard
ranks **efficiency, not wealth**.

---

## 2. Design rules (derived, not decorative)

These are the constraints that every later decision was tested against. When a
proposal violates one, the proposal is wrong — not the rule.

| # | Rule | Why it exists |
|---|---|---|
| R1 | **Spend buys volume, never outcome.** | Curve Racer's fatal flaw: stake size *was* the outcome, so the whale auto-won. |
| R2 | **Leaderboard ranks efficiency, not volume.** | Same flaw, reached through rankings. |
| R3 | **The contract is permanently over-collateralised.** | Burned value stays behind as backing, so every outstanding gem is always covered. |
| R4 | **No price oracle.** | Prices are ETH-denominated. The chain has no stablecoin and no oracle; we do not add a trust assumption. |
| R5 | **The server may delay, never inflate.** | Hunt is off-chain, so the trust surface is liveness, not safety. Stated plainly rather than hidden. |
| R6 | **Pre-graduation settlement is ETH; post-graduation is the game token.** | The `graduated()` signal becomes the feature instead of the bug that broke Curve Racer. |

---

## 3. Core loop

```
hunt (off-chain)  ->  gems settle (on-chain)  ->  spend gems on tools + skills
      ^                                                                |
      +-------------------  hunt again, deeper, rarer  -----------------+
```

- **Buy** gems with ETH. Common and Uncommon only.
- **Hunt** for gems. Rare and above are hunt-only — this is what makes hunting
  worth doing at all.
- **Spend** gems on tools and skills. Gems burn; 5% of the spend accrues to the
  treasury.
- **Redeem** gems for ETH, at face value.
- **Season** ends on a fixed clock. Leaderboard resolves. Repeat.

---

## 4. Gems

Five rarities, ~8× price ladder (see §11 for why this is flagged for retuning).

| Tier | Gem | Price (ETH) | Earned by |
|---|---|---|---|
| Common | Quartz | 0.00005 | buying, or common drops |
| Uncommon | Amber | 0.0004 | buying, or uncommon drops |
| Rare | Sapphire | 0.003 | hunting only |
| Epic | Ruby | 0.025 | hunting only |
| Legendary | Diamond | 0.2 | hunting only |

**Buying is capped at Uncommon.** If Rare+ were purchasable, hunting would be
decorative and the entire game would collapse to "convert ETH to gems."

**Redemption is at face value.** No spread. The burns and the durability costs
are the sinks; a treasury spread would just add a reason for players to distrust
the operator for no balancing gain.

---

## 5. Tools

**Sequential ladder. First tool free.** Tiers unlock one at a time; each needs
the previous tier owned. This is the single most important anti-whale structure
— see §8.

| Tier | Name | Cost (gems) | Unlocks drops up to | Hunt cost (ETH) | Durability (hunts) |
|---|---|---|---|---|---|
| 1 | Hand Pick | free (claimed) | Uncommon | 0.0001 | 20 |
| 2 | Iron Pick | 1,000 | Rare | 0.0002 | 35 |
| 3 | Steel Pick | 8,000 | Epic | 0.0004 | 50 |
| 4 | Diamond Pick | 60,000 | Legendary | 0.0008 | 80 |

**Durability behaviour — breaks, keeps its tier, needs repair.** At zero the
tool keeps its tier and its slot but cannot be swung until repaired. Repair costs
gems and scales with tier.

Rationale: tools are non-tradable, so a tool's tier *is* the player's permanent
progress. Burning it would delete hours of grinding over one bad night. Burning
value is already the sink; destroying the tool would be a second, cruel tax.
Repair-not-burn also turns a dead end into a spend decision.

**Repair cost scales with tier**, and repairs are per-tool. Otherwise a shelf of
tier-1s becomes cheaper to maintain than one good tool, which inverts the ladder
the entire game rests on.

**Soft-lock escape.** A player with zero gems and a broken tool cannot hunt, and
hunting is the only ETH-free source of gems. The exit already exists — Common
gems are purchasable with ETH — and it must be surfaced in the UI as a normal
action, not discovered by getting stuck.

---

## 6. Multiple tools - the tier ladder IS the slot system

Players may own several tools and rotate between them, so a tool hitting zero
mid-season does not halt play.

**The separate slot system was removed, not patched.** There are four tiers,
each claimable exactly once, and each tier requires owning the one below. That
alone caps a player at four tools. The original design added an independent
`MAX_SLOTS` counter, and it was actively harmful: with a base of 1 it locked a
player out of their own ladder, which the tests caught immediately. The concept
was redundant and the redundancy caused the bug.

**A shelf of tools is not power.** Each tool carries its own durability pool, so
owning four tools means four hunts available and four repairs owed. A whale
banking a shelf of tier-4s has deferred cost, not avoided it. More tools also
means a larger gem sink, which is where a whale's money *should* go.

Rotation is free. Charging for a UI choice would feel like a tax.

**What skill actually raises:** the findable rarity ceiling. Skill 2 opens
Rare, 3 opens Epic, 4 opens Legendary. A whale with unlimited ETH and no skill
is still capped at the tool tier's ceiling.

---

## 7. Skills

Skills are the **earned** half of the progression; tools are the **bought** half.
Money buys speed, play buys ceiling.

Tool tier caps how much of the drop table a tool can reach, but the top rarities
also require skill level, which can only be raised by hunting volume. A whale
who front-loads ETH grinds faster and still cannot skip the hunt.

This is the specific mechanism that stops "buy quartz instead of hunting" from
being a valid strategy: quartz accelerates progression but never unlocks the top
of the ladder.

---

## 8. Why the whale cannot win

Worked through, because this has failed twice already.

1. **Buying is capped at Uncommon.** No ETH path to Rare+.
2. **The drop table depends on tool tier only.** Spending more ETH does not
   improve odds. It buys more *hunts*, and hunts cost ETH, so volume is
   self-financing-neutral at best and self-defeating at worst.
3. **Skills are hunt-earned.** The ceiling is not purchasable.
4. **Slots are skill-earned.** Working capital is not purchasable.
5. **The leaderboard measures rarity-weight per ETH spent** (see §9), which is
   scale-invariant by construction.

A whale with 10,000 ETH who plays *identically* to a player with 1 ETH posts an
**identical** ROI. They get there sooner. That is the entire difference, and it
is a fair one.

### What open settlement changed, precisely

Settlement is verified against a season seed committed on chain before any hunt,
and the result is derived from `(seed, season, player, hunt index)`. So two
players playing *identically* no longer receive the *identical* find -- they
receive independent draws from the same distribution.

The fairness claim above survives intact, because it was never about individual
outcomes. The drop table depends on tool tier alone (rule 2), so expected
rarity-weight per ETH spent is unchanged: identical ROI in expectation, and the
whale still gets there sooner by hunting more. What changed is only that per-hunt
results are now *independent* rather than identical.

Two consequences worth stating plainly rather than burying:

- **Per-roll equality is gone.** Two players can play identically and see
  different finds. Anyone reading "identical ROI" as "the same find" would be
  wrong.
- **The seed publisher chooses the outcome set.** Committing a seed binds the
  season's randomness, so nobody can rewrite history after players have acted --
  but whoever commits it decides what the season contains. Commit-before-hunt
  prevents *selection*; it does not by itself prove the seed was chosen fairly.
  Publish the seed before committing it, or that guarantee is empty.

This is a deliberate trade of per-roll equality for the removal of the keeper:
open settlement means no trusted party, and independence is the price.

---

## 9. Season leaderboard

Seasons are 14 days, auto-rolled, permissionless finalisation.

| Board | Metric | Purpose |
|---|---|---|
| **Primary — ROI** | rarity-weight earned ÷ ETH spent | Scale-invariant. 10,000 ETH at 20% ties 1 ETH at 20%. |
| **Secondary — Best find** | single highest-value gem | Rewards nerve, not hours. |
| **Tertiary — Legendary-equivalents** | rarity-weighted total | Makes a Diamond worth hunting for over 40 Quartz. |

**Minimum splay floor (0.005 ETH).** Without it, a player who makes one lucky
hunt and quits posts a perfect ratio on a tiny denominator and tops the board.
The floor is set low — roughly one mid-tier tool.

**Top 10 take prizes.** Chosen over winner-take-all deliberately: less brutal,
and it gives more reasons to keep playing through a season.

**Commit-then-act.** The hunter must publish the season's outcome merkle root
before any hunt of that season. Anti-frontrunning: results cannot be rewritten
after players have seen and acted on them.

**Prize trust caveat.** Gems are off-chain, so a public board is an
verifiable-in-principle but *unverifiable-in-practice* claim attached to
rewards. Mitigations: per-hunt signatures, a published hash chain, and players
auditing their own record. **Keep prizes off-chain** (cosmetics, season pass,
tool perks) so the board stays a game rather than a payment-security problem. If
prizes ever pay onchain, the operator becomes a gatekeeper on funds and this
whole risk profile changes.

---

## 10. Economy and solvency

**The invariant.** Every gem sold mints ETH into the contract. Redemptions pay
ETH out. Spending burns gems, plus 5% to the treasury. Burned value therefore
stays in the contract as backing, so the contract is **permanently
over-collateralised by the total burned**. That is what makes fixed gem values
honest without any price feed.

Trace: player buys 100 gems for 0.01 ETH → contract holds 0.01 ETH, owes 100
gems. Player spends 100 on tools → 95 burn, 5 to treasury. Contract still holds
0.01 ETH but now owes far less. The burned value is now free collateral.

**Treasury.** Accrues the 5% as gems, redeems in bulk for ETH when convenient.
Holding fees in *gem* units rather than ETH is deliberate — it forces the
treasury to redeem on its own schedule instead of whenever ETH is convenient.

**Hunt cost scales with tier** (0.0001 → 0.0008 ETH). Higher tools swing harder
and are more expensive to use. The cost feeds the ROI denominator, so playing
more always costs more — volume is never free.

---

## 11. Open questions and known risks

**Flagged for retuning: the 8× price ladder.** A tier-4 hunt nets roughly 80×
a tier-1 hunt in expected value. That may be correct — the top of the ladder
*should* feel powerful — but it means a maxed player completes a season's
grinding in one hunt. Flattening the step to ~4× steepens effort without a cliff
in payoff. Tune against observed find-rates, not on paper.

**No USD pricing — deliberate for testnet (§R4).** Gems are priced in ETH, so
no oracle is needed. A player's gem *count* is stable; only the ETH value of
that count moves with the market. On testnet this is a non-issue (ETH is free
and has no real price).

**Mainnet migration path.** If DeepWood ever ships to mainnet, we re-denominate:
switch gem prices to USD, back them by a real price feed (Chainlink or similar),
and take redemption in the game token. The contract reads its price source from
a configurable address precisely so this is a config change, not a rewrite. The
structural design (backing = liability + burned surplus) is denomination-
agnostic, so the migration is a pricing-layer change only.

**The hunter can withhold.** R5. The hunter can delay or censor a good result;
it cannot inflate one. This is a liveness assumption. It is a real
centralisation and is documented rather than papered over.

**Redemption rail post-graduation is unwired.** Pre-graduation settles in ETH.
Post-graduation is intended to settle in the game token, but the token is not
transferable yet and the contract holds **zero** of it, so the first
post-graduation claim is unpayable. Resolution: a **grace window** after
graduation during which redemption still settles in ETH while the treasury
acquires the token. Cheapest option, and it assumes nothing about when
graduation lands.

**Post-graduation numbers get large.** At the token's observed rate, a 0.00005
ETH gem is ~17,000,000 token units. Redemption UI will need large-number
formatting and possibly a decimals rethink.

**The 10% token discount is load-bearing.** It is not decoration: it is the
mechanism that causes players to pay in the game token, which is how the
contract accumulates the inventory needed to honour post-graduation redemption.
If someone later "simplifies" it to a flat price, redemption breaks. Documented
here so it survives.

---

## 12. Deliberately rejected

| Idea | Why not |
|---|---|
| Stake-size winner | R1. Auto-win for the whale. |
| USD-denominated gems | Needs an oracle. The chain has no stablecoin and no reference. |
| Tradable tool NFTs | Lifespans turn tools into depreciating financial assets; players trade around the decay instead of playing. Durability already solves the endgame problem (maxing being permanent). Tools stay off-chain and non-tradable. |
| Selling gems for ETH *and* stables | Drains the reserve and invites arbitrage. Redemption is ETH-only, then token-only. |
| Off-chain authority on payouts | R5 boundary. Settlement is on-chain by construction. |

---

## 13. Build order

1. Contract: gems, buy, hunt settlement, spend, redeem, solvency invariant.
2. Invariant tests — solvency must hold across every path that moves value.
3. Off-chain hunt engine: drop rolls against the committed root.
4. Season + leaderboard with the splay floor.
5. Tool rotation, repair, slots.
6. Frontend.
7. Playtest and retune the ladder against real find-rates.

Steps 1–2 are the ones that cannot be skipped. The ladder numbers are
provisional until step 7.

---

## 14. Build state

Steps 1-4 are done and tested. Nothing is deployed; no token exists.

| Step | State |
|---|---|
| 1. Contract | `src/DeepWood.sol` - done |
| 2. Invariant tests | `test/DeepWood.t.sol` - 37/37, grouped by rule |
| 3. Hunt engine | `script/hunt-engine.mjs` - done, 200k-sample distribution check |
| 4. Season + leaderboard | In the contract; no off-chain board yet |
| 5. Tools, repair, rotation | In the contract and tested |
| 6. Frontend | Not started |
| 7. Playtest + retune | Blocked on the frontend |

Run `npm test` for both suites.

### Bugs the tests caught

Seven so far, all the same species - plausible code doing something wrong:

1. `claimTool(1)` was repeatable, minting unlimited free tools.
2. ROI truncated to 0 for any real spend, so the anti-whale test compared
   zeros. The protection existed in name only.
3. `maxFindableRarity` capped tier-1 at Common while `dropTable(1)` allows
   10% Uncommon, so the contract rejected its own table's results.
4. A skill off-by-one meant Epic was unreachable at skill 3 and Legendary at 4.
5. Skill unlocks started `false`, so a brand-new player could not find even
   Common - a dead end, not a difficulty curve.
6. Fixing (1) with a `MAX_SLOTS` cap locked players out of their own ladder.
   A regression, caught by my own test.
7. The merkle leaf omitted the seed, so every seed produced an identical
   root and `verifySeason` passed for ANY seed - the engine could swap the
   seed after committing and still match. This was the exact attack the
   commitment exists to prevent.

Each is now covered by a named regression test.
