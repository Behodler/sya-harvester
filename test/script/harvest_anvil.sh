#!/usr/bin/env bash
# Story 005 — Anvil mainnet-fork test for the operator script `script/harvest.sh`.
#
# Starts anvil on a mainnet fork (story 004's pinned block by default), deploys and configures a harvester
# with 004's routes and V4 pool key (test/script/DeployHarvesterForTest.s.sol), provisions a claim NFT and
# the NFTMinter approval for the operator, creates the operator as a FRESH random key inside a TEMPORARY
# Foundry keystore, and drives `script/harvest.sh` through:
#   1. a raw private key in the environment          -> refused, no tx sent
#   2. an unprofitable run (huge MIN_PROFIT_WEI)     -> aborts before sending, nonce unchanged, exit != 0
#   3. a simulated revert (DOLA route cleared)       -> aborts, prints RouteNotConfigured(<DOLA>), no tx sent
#   4. DRY_RUN=1                                     -> prints minEthOut, exit 0, no tx sent
#   5. a profitable run                              -> exit 0, tx sent, operator ETH up, harvester holds nothing
#
# Usage:
#   MAINNET_RPC_URL=<archive mainnet rpc> test/script/harvest_anvil.sh
# Optional: FORK_BLOCK (default 26261000 = MainnetAddresses.PINNED_BLOCK), ANVIL_PORT (default 8546).
#
# Without MAINNET_RPC_URL the test prints SKIPPED and exits 77: a skip is never reported as a pass.
# The temp keystore lives under a mktemp dir that is deleted on exit; nothing is written to the repo
# except forge's gitignored cache/out and broadcast/*/31337/ (anvil runs with --chain-id 31337).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARVEST_SH="$ROOT/script/harvest.sh"

if [[ -z "${MAINNET_RPC_URL:-}" ]]; then
  echo "SKIPPED: MAINNET_RPC_URL is not set (needs an archive-capable mainnet RPC). Not a pass."
  exit 77
fi

FORK_BLOCK="${FORK_BLOCK:-26261000}"
ANVIL_PORT="${ANVIL_PORT:-8546}"
RPC="http://127.0.0.1:${ANVIL_PORT}"

# --- Mainnet addresses (test/fork/MainnetAddresses.sol) ---
NFT_MINTER=0x39Af088408e815844c567037C157B31d48d2E10F
NFT_HOLDER=0x025494682Fb33792145F1a459555C7000BaB53C4
NFT_INDEX=1
USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
DOLA=0x865377367054516e17014CcdED1e7d814EDC9ce4
USDE=0x4c9EDD5852cd905f086C759E8383e09bff1E68B3
CRVUSD=0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E

# Anvil default account 0 deploys and owns the harvester (unlocked on anvil, no key needed).
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
# The operator is NOT an Anvil default account: those publicly known keys carry EIP-7702 delegations on
# mainnet (account 1 has code 0xef0100...), so the NFTMinter's ERC1155 receiver check reverts on them. The
# operator is instead created below as a fresh random key written straight into a temp keystore, so
# harvest.sh is exercised through `--account` exactly as on mainnet and no raw key ever exists in this script.
# A dummy, never-funded key used only to prove harvest.sh refuses raw private keys (case 1).
DUMMY_RAW_KEY=0x00000000000000000000000000000000000000000000000000000000000000a1

TMP="$(mktemp -d)"
ANVIL_PID=""
cleanup() {
  if [[ -n "$ANVIL_PID" ]]; then kill "$ANVIL_PID" 2>/dev/null || true; wait "$ANVIL_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "== Starting anvil (fork block $FORK_BLOCK, port $ANVIL_PORT)"
anvil --fork-url "$MAINNET_RPC_URL" --fork-block-number "$FORK_BLOCK" --chain-id 31337 \
  --port "$ANVIL_PORT" --silent >"$TMP/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 120); do
  if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
cast chain-id --rpc-url "$RPC" >/dev/null || { echo "anvil did not start"; cat "$TMP/anvil.log"; exit 1; }

# Keep fork time at the pinned block's timestamp (+1h of accrual, as the 004 fork suite warps). Anvil
# otherwise follows the wall clock, and the USDC strategy's oracle reverts once its Chainlink feed is stale.
FORK_TS="$(cast block "$FORK_BLOCK" --field timestamp --rpc-url "$RPC")"
cast rpc anvil_setTime "$((FORK_TS + 3600))" --rpc-url "$RPC" >/dev/null

echo "== Deploying and configuring the harvester (004's routes and pool key)"
DEPLOY_OUT="$(cd "$ROOT" && forge script test/script/DeployHarvesterForTest.s.sol:DeployHarvesterForTest \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$OWNER" 2>&1)" || { echo "$DEPLOY_OUT"; exit 1; }
HARVESTER="$(grep -oE 'HARVESTER=0x[0-9a-fA-F]{40}' <<<"$DEPLOY_OUT" | head -1 | cut -d= -f2)"
[[ -n "$HARVESTER" ]] || { echo "$DEPLOY_OUT"; echo "could not parse harvester address"; exit 1; }
echo "   harvester: $HARVESTER"

echo "== Creating the operator in a temporary keystore (HOME=$TMP/home)"
# A throwaway HOME makes `--account harvest-test-operator` resolve to $TMP/home/.foundry/keystores, so the
# real keystore directory is never touched and nothing key-related can land in the repo.
KS_DIR="$TMP/home/.foundry/keystores"
mkdir -p "$KS_DIR"
printf 'anvil-test-only' >"$TMP/password"
KS_OUT="$(cast wallet new "$KS_DIR" --unsafe-password "$(cat "$TMP/password")")"
KS_FILE="$(grep -oE 'keystore file: .*' <<<"$KS_OUT" | sed 's/^keystore file: //')"
OPERATOR="$(grep -oE '0x[0-9a-fA-F]{40}' <<<"$KS_OUT" | head -1)"
mv "$KS_FILE" "$KS_DIR/harvest-test-operator"
[[ -z "$(cast code "$OPERATOR" --rpc-url "$RPC" | sed 's/^0x$//')" ]] || { echo "operator has code"; exit 1; }
cast rpc anvil_setBalance "$OPERATOR" 0x8ac7230489e80000 --rpc-url "$RPC" >/dev/null # 10 ETH
echo "   operator: $OPERATOR"

echo "== Provisioning claim NFT index $NFT_INDEX and approval for the operator"
cast rpc anvil_impersonateAccount "$NFT_HOLDER" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$NFT_HOLDER" 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null
cast send --rpc-url "$RPC" --unlocked --from "$NFT_HOLDER" "$NFT_MINTER" \
  "safeTransferFrom(address,address,uint256,uint256,bytes)" "$NFT_HOLDER" "$OPERATOR" "$NFT_INDEX" 1 0x >/dev/null
cast rpc anvil_stopImpersonatingAccount "$NFT_HOLDER" --rpc-url "$RPC" >/dev/null
cast rpc anvil_impersonateAccount "$OPERATOR" --rpc-url "$RPC" >/dev/null
cast send --rpc-url "$RPC" --unlocked --from "$OPERATOR" "$NFT_MINTER" \
  "setApprovalForAll(address,bool)" "$HARVESTER" true >/dev/null
cast rpc anvil_stopImpersonatingAccount "$OPERATOR" --rpc-url "$RPC" >/dev/null
[[ "$(cast call --rpc-url "$RPC" "$NFT_MINTER" "balanceOf(address,uint256)(uint256)" "$OPERATOR" "$NFT_INDEX")" == "1" ]] \
  || { echo "operator did not receive the NFT"; exit 1; }


# Runs harvest.sh against anvil with the temp keystore. Extra env assignments come in as arguments.
run_harvest() {
  env -u ETH_PRIVATE_KEY -u PRIVATE_KEY \
    HOME="$TMP/home" \
    PATH="$PATH" \
    MAINNET_RPC_URL="$RPC" \
    PRIVATE_RPC_URL="$RPC" \
    HARVESTER="$HARVESTER" \
    NFT_INDEX="$NFT_INDEX" \
    KEYSTORE_ACCOUNT=harvest-test-operator \
    KEYSTORE_PASSWORD_FILE="$TMP/password" \
    "$@" bash "$HARVEST_SH"
}

nonce() { cast nonce "$OPERATOR" --rpc-url "$RPC"; }
balance() { cast balance "$1" --rpc-url "$RPC"; }
erc20() { cast call --rpc-url "$RPC" "$1" "balanceOf(address)(uint256)" "$2" | awk '{print $1}'; }

if [[ ! -f "$HARVEST_SH" ]]; then
  echo "FAIL: $HARVEST_SH does not exist"
  exit 1
fi

# ---------------------------------------------------------------------------------------------------------
echo "== Case 1: a raw private key in the environment is refused"
N0="$(nonce)"
set +e
OUT="$(run_harvest ETH_PRIVATE_KEY="$DUMMY_RAW_KEY" 2>&1)"; RC=$?
set -e
echo "$OUT" | sed 's/^/     | /'
[[ $RC -ne 0 ]] && pass "exit code $RC" || fail "expected non-zero exit, got $RC"
grep -qi "private key" <<<"$OUT" && pass "refusal message mentions the private key" || fail "no refusal message"
grep -q "$DUMMY_RAW_KEY" <<<"$OUT" && fail "the raw key was echoed" || pass "the raw key was not echoed"
[[ "$(nonce)" == "$N0" ]] && pass "nonce unchanged ($N0)" || fail "nonce moved"

# ---------------------------------------------------------------------------------------------------------
echo "== Case 2: unprofitable after gas and margin -> abort before sending"
N0="$(nonce)"
set +e
OUT="$(run_harvest MIN_PROFIT_WEI=10000000000000000000 2>&1)"; RC=$?
set -e
echo "$OUT" | sed 's/^/     | /'
[[ $RC -ne 0 ]] && pass "exit code $RC" || fail "expected non-zero exit, got $RC"
grep -qi "not profitable" <<<"$OUT" && pass "clear 'not profitable' message" || fail "no 'not profitable' message"
grep -q "simulatedEthOut" <<<"$OUT" && pass "numbers printed" || fail "numbers not printed"
[[ "$(nonce)" == "$N0" ]] && pass "nonce unchanged ($N0)" || fail "nonce moved"
grep -q "anvil-test-only" <<<"$OUT" && fail "keystore password echoed" || pass "keystore password not echoed"

# ---------------------------------------------------------------------------------------------------------
echo "== Case 3: simulated revert (DOLA route cleared) -> decoded reason, abort"
SNAP="$(cast rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')"
cast send --rpc-url "$RPC" --unlocked --from "$OWNER" "$HARVESTER" "clearRoute(address)" "$DOLA" >/dev/null
N0="$(nonce)"
set +e
OUT="$(run_harvest 2>&1)"; RC=$?
set -e
echo "$OUT" | sed 's/^/     | /'
[[ $RC -ne 0 ]] && pass "exit code $RC" || fail "expected non-zero exit, got $RC"
grep -q "RouteNotConfigured" <<<"$OUT" && pass "RouteNotConfigured decoded by name" || fail "RouteNotConfigured not decoded"
grep -qi "$DOLA" <<<"$OUT" && pass "the offending token (DOLA) is printed" || fail "DOLA address not printed"
[[ "$(nonce)" == "$N0" ]] && pass "nonce unchanged ($N0)" || fail "nonce moved"
cast rpc evm_revert "$SNAP" --rpc-url "$RPC" >/dev/null

# ---------------------------------------------------------------------------------------------------------
echo "== Case 4: DRY_RUN=1 computes minEthOut and stops"
N0="$(nonce)"
set +e
OUT="$(run_harvest DRY_RUN=1 PRIORITY_FEE_WEI=100000000 2>&1)"; RC=$?
set -e
echo "$OUT" | sed 's/^/     | /'
[[ $RC -eq 0 ]] && pass "exit code 0" || fail "expected exit 0, got $RC"
grep -q "minEthOut" <<<"$OUT" && pass "minEthOut printed" || fail "minEthOut not printed"
grep -qi "dry run" <<<"$OUT" && pass "dry-run notice printed" || fail "no dry-run notice"
[[ "$(nonce)" == "$N0" ]] && pass "nonce unchanged ($N0)" || fail "nonce moved"

# ---------------------------------------------------------------------------------------------------------
echo "== Case 5: profitable run -> sends, operator ETH rises, harvester holds nothing"
N0="$(nonce)"
B0="$(balance "$OPERATOR")"
set +e
OUT="$(run_harvest PRIORITY_FEE_WEI=100000000 2>&1)"; RC=$?
set -e
echo "$OUT" | sed 's/^/     | /'
B1="$(balance "$OPERATOR")"
[[ $RC -eq 0 ]] && pass "exit code 0" || fail "expected exit 0, got $RC"
[[ "$(nonce)" == "$((N0 + 1))" ]] && pass "exactly one tx sent (nonce $N0 -> $((N0 + 1)))" || fail "nonce $N0 -> $(nonce)"
if [[ "$(echo "$B1 > $B0" | bc)" == "1" ]]; then
  pass "operator ETH rose by $(echo "$B1 - $B0" | bc) wei net of gas"
else
  fail "operator ETH did not rise ($B0 -> $B1)"
fi
grep -qiE "status[[:space:]]+1|success" <<<"$OUT" && pass "receipt status success printed" || fail "no success status"
grep -qE "0x[0-9a-fA-F]{64}" <<<"$OUT" && pass "tx hash printed" || fail "no tx hash"
[[ "$(balance "$HARVESTER")" == "0" ]] && pass "harvester ETH = 0" || fail "harvester ETH = $(balance "$HARVESTER")"
for T in USDC:$USDC DOLA:$DOLA USDE:$USDE CRVUSD:$CRVUSD; do
  B="$(erc20 "${T#*:}" "$HARVESTER")"
  [[ "$B" == "0" ]] && pass "harvester ${T%%:*} = 0" || fail "harvester ${T%%:*} = $B"
done
NB="$(cast call --rpc-url "$RPC" "$NFT_MINTER" "balanceOf(address,uint256)(uint256)" "$HARVESTER" "$NFT_INDEX")"
[[ "$NB" == "0" ]] && pass "harvester NFT[$NFT_INDEX] = 0" || fail "harvester NFT[$NFT_INDEX] = $NB"
OB="$(cast call --rpc-url "$RPC" "$NFT_MINTER" "balanceOf(address,uint256)(uint256)" "$OPERATOR" "$NFT_INDEX")"
[[ "$OB" == "0" ]] && pass "operator's NFT unit was burned by SYA" || fail "operator NFT[$NFT_INDEX] = $OB"

echo
echo "== $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
