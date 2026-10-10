#!/usr/bin/env bash
# Redeploy DeepWoodV4 with the fixed migration, then restore every knob the
# previous deploy had (token, rail, graduated flag, seed, open season).
# Env is read from .deploy.v4.env by forge itself -- the private key never
# appears on a command line.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$HOME/gem-hunter"
RPC="${1:-https://rpc.testnet.chain.robinhood.com}"

echo "==> deploying DeepWoodV4 (fixed migration) to $RPC"
forge script script/DeployV4.s.sol:DeployV4 \
  --rpc-url "$RPC" \
  --broadcast \
  2>&1 | tee /tmp/dw_deploy_v4.log | grep -Ei "contract address|txn|error|revert|Script ran|Gas used|Script Successfully|Deployed" | head -30

echo "==> extracting deployed address"
python3 - << 'PY'
import re
log = open('/tmp/dw_deploy_v4.log').read()
# forge prints the deployed address in the "### Deployed contract" line, or in
# the transaction list when the contract creation is broadcast.
m = re.findall(r'Deployed contract\s*:\s*(0x[0-9a-fA-F]{40})', log)
if not m:
    m = re.findall(r'Contract Address:\s*(0x[0-9a-fA-F]{40})', log)
if m:
    print("V4_NEW=" + m[0])
    open('/tmp/dw_v4_new.txt','w').write(m[0])
else:
    print("V4_NEW=NOT_FOUND")
PY
