#!/usr/bin/env bash
# SYAHarvester operator script: simulate with real fees, derive a gas-covering minEthOut, submit privately.
#
# Needs only Foundry (`cast`) plus bash and `bc` (integer wei maths). No Node.
#
#   1. Price gas from the latest base fee: maxFeePerGas = 2 * baseFee + PRIORITY_FEE_WEI.
#   2. Estimate gas for harvest(exempt, nftIndex, 0) from the operator WITH the fee fields set, and apply
#      GAS_LIMIT_MARGIN_BPS -> gasLimit.
#   3. Simulate harvest(exempt, nftIndex, 0) from the operator with the same fee fields and that gasLimit, so
#      tx.gasprice is non-zero and the contract's on-chain `Unprofitable` gas check really runs. (A wallet
#      simulation at gas price 0 passes that check trivially.) Decode ethOut; on revert, decode and abort.
#   4. minEthOut = max(ethOut * (10000 - SLIPPAGE_BPS) / 10000, gasLimit * maxFeePerGas + MIN_PROFIT_WEI).
#      Abort if minEthOut > ethOut.
#   5. Unless DRY_RUN=1, `cast send` through PRIVATE_RPC_URL (default Flashbots Protect) signed by a Foundry
#      keystore account. Raw private keys are refused.
#
# Every input is an env var, overridable by a flag (flags win). Run with --help for the list.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: script/harvest.sh [flags]

Env var (flag)                                   Meaning                                      Default
HARVESTER (--harvester ADDR)                     SYAHarvester address                         required
EXEMPT_STRATEGIES (--exempt A,B,...)             comma-separated strategies to exempt         empty
NFT_INDEX (--nft-index N)                        claim NFT index (0 = none, only valid once   required
                                                 SYA's NFT gating is off)
SLIPPAGE_BPS (--slippage-bps N)                  haircut on the simulated ethOut              50
MIN_PROFIT_WEI (--min-profit-wei N)              profit floor above the gas bound             0
GAS_LIMIT_MARGIN_BPS (--gas-limit-margin-bps N)  margin on the gas estimate                   2000
PRIORITY_FEE_WEI (--priority-fee-wei N|auto)     tip; "auto" = eth_maxPriorityFeePerGas       1000000000
MAINNET_RPC_URL / ETH_RPC_URL (--rpc-url URL)    read RPC (estimate + simulation)             required
PRIVATE_RPC_URL (--private-rpc-url URL)          submission relay                             https://rpc.flashbots.net
KEYSTORE_ACCOUNT (--account NAME)                Foundry keystore account (cast wallet import) required to send
KEYSTORE_PASSWORD_FILE (--password-file PATH)    keystore password file (else cast prompts)   unset
OPERATOR (--operator ADDR)                       sender address; derived from the keystore    derived
                                                 if unset (must match it when sending)
RECEIPT_TIMEOUT (--receipt-timeout SECONDS)      how long cast waits for the receipt          600
RPC_TIMEOUT (--rpc-timeout SECONDS)              per-request RPC timeout for cast             120
DRY_RUN (--dry-run)                              stop after computing minEthOut               0

Raw private keys are refused: --private-key, --mnemonic, and the ETH_PRIVATE_KEY / PRIVATE_KEY /
ETH_MNEMONIC env vars all abort the script before anything is sent.
EOF
}

die() { echo "ABORT: $*" >&2; exit 1; }

# ---------------------------------------------------------------- refuse raw keys before anything else
for v in ETH_PRIVATE_KEY PRIVATE_KEY ETH_MNEMONIC MNEMONIC; do
  if [[ -n "${!v:-}" ]]; then
    die "raw private key material found in \$$v. This script only signs with a Foundry keystore account (KEYSTORE_ACCOUNT / --account). Unset $v and import the key with 'cast wallet import'."
  fi
done

# ---------------------------------------------------------------- flags (override env vars)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harvester) HARVESTER="$2"; shift 2 ;;
    --exempt) EXEMPT_STRATEGIES="$2"; shift 2 ;;
    --nft-index) NFT_INDEX="$2"; shift 2 ;;
    --slippage-bps) SLIPPAGE_BPS="$2"; shift 2 ;;
    --min-profit-wei) MIN_PROFIT_WEI="$2"; shift 2 ;;
    --gas-limit-margin-bps) GAS_LIMIT_MARGIN_BPS="$2"; shift 2 ;;
    --priority-fee-wei) PRIORITY_FEE_WEI="$2"; shift 2 ;;
    --rpc-url) MAINNET_RPC_URL="$2"; shift 2 ;;
    --private-rpc-url) PRIVATE_RPC_URL="$2"; shift 2 ;;
    --account) KEYSTORE_ACCOUNT="$2"; shift 2 ;;
    --password-file) KEYSTORE_PASSWORD_FILE="$2"; shift 2 ;;
    --operator) OPERATOR="$2"; shift 2 ;;
    --receipt-timeout) RECEIPT_TIMEOUT="$2"; shift 2 ;;
    --rpc-timeout) RPC_TIMEOUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --private-key|--private-key=*|--mnemonic|--mnemonic=*|--interactive)
      die "$1 is refused: raw private keys are never accepted. Use a Foundry keystore account (--account NAME)." ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------- inputs and defaults
READ_RPC="${MAINNET_RPC_URL:-${ETH_RPC_URL:-}}"
HARVESTER="${HARVESTER:-}"
EXEMPT_STRATEGIES="${EXEMPT_STRATEGIES:-}"
NFT_INDEX="${NFT_INDEX:-}"
SLIPPAGE_BPS="${SLIPPAGE_BPS:-50}"
MIN_PROFIT_WEI="${MIN_PROFIT_WEI:-0}"
GAS_LIMIT_MARGIN_BPS="${GAS_LIMIT_MARGIN_BPS:-2000}"
PRIORITY_FEE_WEI="${PRIORITY_FEE_WEI:-1000000000}"
PRIVATE_RPC_URL="${PRIVATE_RPC_URL:-https://rpc.flashbots.net}"
KEYSTORE_ACCOUNT="${KEYSTORE_ACCOUNT:-}"
KEYSTORE_PASSWORD_FILE="${KEYSTORE_PASSWORD_FILE:-}"
OPERATOR="${OPERATOR:-}"
RECEIPT_TIMEOUT="${RECEIPT_TIMEOUT:-600}"
RPC_TIMEOUT="${RPC_TIMEOUT:-120}"
DRY_RUN="${DRY_RUN:-0}"

command -v cast >/dev/null || die "cast (Foundry) is not on PATH"
command -v bc >/dev/null || die "bc is not on PATH"

[[ -n "$READ_RPC" ]] || die "set MAINNET_RPC_URL (or ETH_RPC_URL, or --rpc-url): the read RPC for estimation and simulation"
[[ "$HARVESTER" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "HARVESTER must be an address (got '${HARVESTER}')"
[[ "$NFT_INDEX" =~ ^[0-9]+$ ]] || die "NFT_INDEX is required: a claim NFT index you hold (0 = none, only valid once SYA's NFT gating is off)"
isuint() { [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer (got '$2')"; }
isuint SLIPPAGE_BPS "$SLIPPAGE_BPS"
isuint MIN_PROFIT_WEI "$MIN_PROFIT_WEI"
isuint GAS_LIMIT_MARGIN_BPS "$GAS_LIMIT_MARGIN_BPS"
isuint RECEIPT_TIMEOUT "$RECEIPT_TIMEOUT"
isuint RPC_TIMEOUT "$RPC_TIMEOUT"
(( SLIPPAGE_BPS <= 10000 )) || die "SLIPPAGE_BPS must be <= 10000"
[[ "$DRY_RUN" == "0" || "$DRY_RUN" == "1" ]] || die "DRY_RUN must be 0 or 1"

EXEMPT_ARG="[]"
if [[ -n "${EXEMPT_STRATEGIES// /}" ]]; then
  EXEMPT_CLEAN="${EXEMPT_STRATEGIES// /}"
  IFS=',' read -r -a EXEMPT_LIST <<<"$EXEMPT_CLEAN"
  for a in "${EXEMPT_LIST[@]}"; do
    [[ "$a" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "EXEMPT_STRATEGIES entry is not an address: '$a'"
  done
  EXEMPT_ARG="[$EXEMPT_CLEAN]"
fi

# Wallet args for cast. Only the keystore path exists; the password goes via file or cast's hidden prompt
# and is never placed on a command line or printed.
WALLET_ARGS=()
if [[ -n "$KEYSTORE_ACCOUNT" ]]; then
  WALLET_ARGS=(--account "$KEYSTORE_ACCOUNT")
  if [[ -n "$KEYSTORE_PASSWORD_FILE" ]]; then
    [[ -r "$KEYSTORE_PASSWORD_FILE" ]] || die "KEYSTORE_PASSWORD_FILE is not readable"
    WALLET_ARGS+=(--password-file "$KEYSTORE_PASSWORD_FILE")
  fi
fi

if [[ "$DRY_RUN" != "1" && -z "$KEYSTORE_ACCOUNT" ]]; then
  die "KEYSTORE_ACCOUNT (--account) is required to send. Import the key once with 'cast wallet import <name> --interactive'."
fi

if [[ -n "$KEYSTORE_ACCOUNT" ]]; then
  KS_ADDR="$(cast wallet address "${WALLET_ARGS[@]}")" || die "could not unlock keystore account '$KEYSTORE_ACCOUNT'"
  if [[ -n "$OPERATOR" && "${OPERATOR,,}" != "${KS_ADDR,,}" ]]; then
    die "OPERATOR ($OPERATOR) does not match keystore account '$KEYSTORE_ACCOUNT' ($KS_ADDR)"
  fi
  OPERATOR="$KS_ADDR"
fi
[[ "$OPERATOR" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "set OPERATOR (or KEYSTORE_ACCOUNT) so the simulation runs from your address"

SIG="harvest(address[],uint256,uint256)"

# ---------------------------------------------------------------- revert decoding
# Known custom errors of SYAHarvester. cast prints the raw revert data; match its selector by name.
KNOWN_ERRORS=(
  "Unprofitable(uint256,uint256)"
  "InsufficientEthOut(uint256,uint256)"
  "RouteNotConfigured(address)"
  "EthPoolNotSet()"
  "EthTransferFailed()"
  "NotPoolManager()"
  "ZeroAddress()"
  "InvalidEthPool()"
  "InvalidRouteStart(address,address)"
  "InvalidRouteEnd(address,address)"
  "InvalidRouteGap(uint256)"
  "InvalidRouteToken(uint256)"
  "InvalidRouteSwapParams(uint256)"
  "InvalidRoutePools(uint256)"
)
decode_revert() {
  local out="$1" data sel e esig args
  # Raw revert data, if cast printed any (longest 0x-hex run that is a whole number of 4-byte words + 4)
  data="$(grep -oE '0x[0-9a-fA-F]{8,}' <<<"$out" | awk '{ if ((length($0) - 10) % 64 == 0) print }' | tail -1 || true)"
  if [[ -n "$data" ]]; then
    sel="${data:0:10}"
    for e in "${KNOWN_ERRORS[@]}"; do
      esig="$(cast sig "$e")"
      if [[ "${sel,,}" == "${esig,,}" ]]; then
        args="$(cast decode-error --sig "$e" "$data" 2>/dev/null | sed 's/ \[[^]]*\]//' | paste -sd, - | sed 's/,/, /g' || true)"
        echo "${e%%(*}(${args})"
        return
      fi
    done
  fi
  # Error(string) and anything else: cast already renders the reason; pass its message through
  grep -oE 'execution reverted.*' <<<"$out" | head -1 || echo "${out}" | tail -3
}

# ---------------------------------------------------------------- 1. fees
CHAIN_ID="$(cast chain-id --rpc-url "$READ_RPC")"
BASE_FEE="$(cast base-fee --rpc-url "$READ_RPC")"
if [[ "$PRIORITY_FEE_WEI" == "auto" ]]; then
  PRIORITY_FEE_WEI="$(cast to-dec "$(cast rpc eth_maxPriorityFeePerGas --rpc-url "$READ_RPC" | tr -d '"')")"
fi
isuint PRIORITY_FEE_WEI "$PRIORITY_FEE_WEI"
(( PRIORITY_FEE_WEI > 0 )) || die "PRIORITY_FEE_WEI must be > 0 so tx.gasprice is non-zero in simulation"
MAX_FEE="$(echo "2 * $BASE_FEE + $PRIORITY_FEE_WEI" | bc)"
FEE_ARGS=(--gas-price "$MAX_FEE" --priority-gas-price "$PRIORITY_FEE_WEI" --rpc-timeout "$RPC_TIMEOUT")

echo "chainId              $CHAIN_ID"
echo "harvester            $HARVESTER"
echo "operator             $OPERATOR"
echo "exemptStrategies     $EXEMPT_ARG"
echo "nftIndex             $NFT_INDEX"
echo "baseFee              $BASE_FEE wei"
echo "maxPriorityFeePerGas $PRIORITY_FEE_WEI wei"
echo "maxFeePerGas         $MAX_FEE wei"

# ---------------------------------------------------------------- 2. estimate (fee fields set)
set +e
EST_OUT="$(cast estimate --rpc-url "$READ_RPC" --from "$OPERATOR" "${FEE_ARGS[@]}" \
  "$HARVESTER" "$SIG" "$EXEMPT_ARG" "$NFT_INDEX" 0 2>&1)"
EST_RC=$?
set -e
if [[ $EST_RC -ne 0 ]]; then
  echo "harvest reverts in simulation (gas estimation with fee fields set):" >&2
  echo "  reason: $(decode_revert "$EST_OUT")" >&2
  die "simulated harvest reverted; nothing sent"
fi
GAS_ESTIMATE="$(awk '{print $1}' <<<"$EST_OUT" | tail -1)"
isuint GAS_ESTIMATE "$GAS_ESTIMATE"
GAS_LIMIT="$(echo "$GAS_ESTIMATE * (10000 + $GAS_LIMIT_MARGIN_BPS) / 10000" | bc)"
echo "gasEstimate          $GAS_ESTIMATE"
echo "gasLimit             $GAS_LIMIT (margin $GAS_LIMIT_MARGIN_BPS bps)"

# ---------------------------------------------------------------- 3. simulate (fee fields set, real gas limit)
set +e
SIM_OUT="$(cast call --rpc-url "$READ_RPC" --from "$OPERATOR" "${FEE_ARGS[@]}" --gas-limit "$GAS_LIMIT" \
  "$HARVESTER" "${SIG}(uint256)" "$EXEMPT_ARG" "$NFT_INDEX" 0 2>&1)"
SIM_RC=$?
set -e
if [[ $SIM_RC -ne 0 ]]; then
  echo "harvest reverts in simulation (eth_call with fee fields set):" >&2
  echo "  reason: $(decode_revert "$SIM_OUT")" >&2
  die "simulated harvest reverted; nothing sent"
fi
SIM_ETH_OUT="$(awk '{print $1}' <<<"$SIM_OUT" | tail -1)"
isuint simulatedEthOut "$SIM_ETH_OUT"

# ---------------------------------------------------------------- 4. minEthOut
SLIPPED="$(echo "$SIM_ETH_OUT * (10000 - $SLIPPAGE_BPS) / 10000" | bc)"
GAS_BOUND="$(echo "$GAS_LIMIT * $MAX_FEE" | bc)"
GAS_FLOOR="$(echo "$GAS_BOUND + $MIN_PROFIT_WEI" | bc)"
if [[ "$(echo "$SLIPPED >= $GAS_FLOOR" | bc)" == "1" ]]; then MIN_ETH_OUT="$SLIPPED"; else MIN_ETH_OUT="$GAS_FLOOR"; fi

echo "simulatedEthOut      $SIM_ETH_OUT wei"
echo "afterSlippage        $SLIPPED wei ($SLIPPAGE_BPS bps)"
echo "gasCostBound         $GAS_BOUND wei (gasLimit * maxFeePerGas)"
echo "minProfit            $MIN_PROFIT_WEI wei"
echo "minEthOut            $MIN_ETH_OUT wei"

if [[ "$(echo "$MIN_ETH_OUT > $SIM_ETH_OUT" | bc)" == "1" ]]; then
  die "not profitable after gas and margin: minEthOut $MIN_ETH_OUT > simulatedEthOut $SIM_ETH_OUT (gasCostBound $GAS_BOUND + minProfit $MIN_PROFIT_WEI); nothing sent"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY RUN: not sending. Would call $HARVESTER $SIG $EXEMPT_ARG $NFT_INDEX $MIN_ETH_OUT"
  exit 0
fi

# ---------------------------------------------------------------- 5. private submission
RELAY_CHAIN_ID="$(cast chain-id --rpc-url "$PRIVATE_RPC_URL")" || die "PRIVATE_RPC_URL did not answer eth_chainId"
[[ "$RELAY_CHAIN_ID" == "$CHAIN_ID" ]] || die "PRIVATE_RPC_URL chain $RELAY_CHAIN_ID != read RPC chain $CHAIN_ID"

echo "relay                $PRIVATE_RPC_URL"
echo "sending harvest($EXEMPT_ARG, $NFT_INDEX, $MIN_ETH_OUT) ..."
set +e
SEND_OUT="$(cast send --rpc-url "$PRIVATE_RPC_URL" "${WALLET_ARGS[@]}" --chain "$CHAIN_ID" \
  --gas-limit "$GAS_LIMIT" "${FEE_ARGS[@]}" --timeout "$RECEIPT_TIMEOUT" \
  "$HARVESTER" "$SIG" "$EXEMPT_ARG" "$NFT_INDEX" "$MIN_ETH_OUT" 2>&1)"
SEND_RC=$?
set -e
grep -vE '^(logs|logsBloom)[[:space:]]' <<<"$SEND_OUT" || true
if [[ $SEND_RC -ne 0 ]]; then
  echo "  reason: $(decode_revert "$SEND_OUT")" >&2
  die "cast send failed"
fi
TX_HASH="$(grep -E '^transactionHash' <<<"$SEND_OUT" | awk '{print $2}')"
STATUS="$(grep -E '^status' <<<"$SEND_OUT" | awk '{print $2}')"
echo "txHash               ${TX_HASH:-unknown}"
echo "receiptStatus        ${STATUS:-unknown}"
[[ "$STATUS" == "1" ]] || die "transaction did not succeed (status ${STATUS:-unknown})"
echo "success"
