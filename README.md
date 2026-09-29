# DeepWood

Season-based gem-hunting game. Ticker `$DEEPWOOD` (not created).

**Nothing is deployed. No token exists.** See SPEC.md for the full design.

## Test

```
npm test          # 37 contract tests + engine statistical checks
```

Contract tests enforce the six design rules in SPEC.md §2 — most importantly
R1 (spend buys volume, never outcome) and R2 (the leaderboard ranks efficiency,
never volume). The engine test samples 200,000 hunts per tool tier to confirm
the realised drop distribution matches the contract's tables.

## Layout

| Path | What |
|---|---|
| `SPEC.md` | The design. Rules, economy, and open questions. |
| `src/DeepWood.sol` | The contract. |
| `test/DeepWood.t.sol` | 37 tests, grouped by the rule they defend. |
| `script/hunt-engine.mjs` | Off-chain hunt: deterministic rolls, merkle commitment. |
| `script/hunt-engine.test.mjs` | Distribution + tamper checks on the engine. |
