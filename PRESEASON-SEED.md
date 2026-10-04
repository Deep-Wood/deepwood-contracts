# Preseason seed

Published BEFORE it was committed on chain. This file is the evidence: git
history cannot be retro-dated without the rewrite showing.

- chain: 46630 (Robinhood Chain Testnet)
- contract: `0x871cb5c1d764788c17d2d9ba7df266c32fe6a7fa`
- seed: `0x66910f0f1c0cd2f9767d369845553d751f83b17031c327b631612d45b25ddf79`

The same deployer address holds `HUNTER_ROLE` (it is the only key held) and
also receives the 5% tool fee. That is exactly why this file has to exist:
an unpublished seed chosen by the fee recipient could be re-rolled at will,
so it proves nothing. Committing it here first is what makes the settlement
verifiable.

Anyone can confirm after the fact that `commitSeed` on chain matches this
value.
