# Deploying DeepWood

**Nothing here has been deployed.** The contract, engine, and deploy script are
written and tested locally. No transaction has been sent to any network.

## Before you can deploy

Three environment variables are required. Two of them are **permanent** --
`TREASURY` and `HUNTER_ROLE` are `immutable` in the constructor, so a wrong
value cannot be patched afterwards. Getting them wrong means a new deployment.

```bash
export PRIVATE_KEY=0x...                    # deployer, must be funded on target chain
export TREASURY_ADDRESS=0x...               # receives the 5% fee
export HUNTER_ADDRESS=0x...                 # the only address allowed to post rolls
```

They must be **different addresses**. The script refuses otherwise: a treasury
that is also the hunter means the fee flow and the roll poster are the same
party, which defeats the split.

## Dry run first — always

This simulates the deployment locally. It does not touch a network and spends
nothing, even with a real key loaded:

```bash
forge script script/Deploy.s.sol:Deploy
```

Add `EXPECTED_CHAIN_ID` so a stale `--rpc-url` can't silently deploy to the
wrong network:

```bash
export EXPECTED_CHAIN_ID=11155111   # Sepolia
forge script script/Deploy.s.sol:Deploy
```

## Actually deploying

Only when you have decided to:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify        # optional
```

Add `--broadcast`. Without it the script only simulates. That is the default
and it is deliberate.

## What happens the moment it deploys

Season 1 starts immediately. `_startSeason(1)` stamps `startsAt` from
`block.timestamp`, and `SEASON_LENGTH` is 14 days. **There is no grace
period** -- the clock is already running before the frontend is live, so any
time between deployment and a working UI is season time that is gone.

This is the main reason not to deploy early.

## Checks that run before deploy

The script refuses to run if:

| Condition | Error |
|---|---|
| `TREASURY_ADDRESS` is zero | `TREASURY_ADDRESS=0` |
| `HUNTER_ADDRESS` is zero | `HUNTER_ADDRESS=0` |
| Treasury equals hunter | `treasury==hunter` |
| `EXPECTED_CHAIN_ID` set and does not match the live chain | `chain id mismatch` |

All four are covered by `test/DeployPreflight.t.sol`.

## Tests

```bash
forge test        # 45 passing
```

`test/DeployPreflight.t.sol` asserts the post-deploy invariants (roles, season
clock, free tier-1 tool) against a real local deployment, plus the script's
guard logic.

It deliberately does **not** call the deploy script. `vm.setEnv` writes to the
real process environment and forge does not roll it back between tests, so a
test that sets a bad value poisons every test that runs after it. Every test
passes in isolation while the suite fails as a group -- which reads exactly
like a contract bug and is not one.
