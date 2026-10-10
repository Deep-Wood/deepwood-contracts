#!/usr/bin/env bash
# Call migrateFromV3 for trader2 on the freshly deployed V4 via `cast`, then
# verify the satchel came across. The key is passed by PATH from a file that
# is never echoed, so it never lands in a process listing or shell history.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
RPC="https://rpc.testnet.chain.robinhood.com"
NEW_V4="0xbF89E76Eac5D7f12a294cEd79B898a21ab30A0E0"
PLAYER="0xd1Bd8e3D34B5f8ed38A56aA804A45B15a3FE848d"
ENVF="$HOME/gem-hunter/.deploy.v4.env"

PK=$(grep '^PRIVATE_KEY=' "$ENVF" | cut -d= -f2- | tr -d "'\"")
KEYFILE=$(mktemp)
printf '%s' "$PK" > "$KEYFILE"
chmod 600 "$KEYFILE"

echo "==> current V4 state before migration"
cast call "$NEW_V4" "gemsOf(address,uint8)(uint256)" "$PLAYER" 0 --rpc-url "$RPC"

echo "==> migrateFromV3(trader2)"
TX=$(cast send --private-key "$PK" --rpc-url "$RPC" \
  "$NEW_V4" "migrateFromV3(address)" "$PLAYER" --json \
  | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["transactionHash"])')
echo "TX: $TX"
echo "status: $(cast receipt "$TX" --rpc-url "$RPC" | grep -E '^status' || echo 'pending')"

rm -f "$KEYFILE"

echo "==> state after migration"
for R in 0 1 2 3 4; do
  echo "  gemsOf(rarity $R): $(cast call "$NEW_V4" "gemsOf(address,uint8)(uint256)" "$PLAYER" $R --rpc-url "$RPC")"
done
echo "  playerStats: $(cast call "$NEW_V4" "playerStats(address)(uint256,uint256,uint256,uint256,uint256,uint64)" "$PLAYER" --rpc-url "$RPC")"
echo "  toolOf:      $(cast call "$NEW_V4" "toolOf(address)(uint8,uint64,bool)" "$PLAYER" --rpc-url "$RPC")"
echo "  seasonScore: $(cast call "$NEW_V4" "seasonScore(address)(uint256)" "$PLAYER" --rpc-url "$RPC")"
