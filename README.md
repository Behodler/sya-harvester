# sya-harvester

Flash-loan helper that claims discounted yield from `StableYieldAccumulator`, sells it, repays the
flash loan, and returns the surplus to the caller as ETH. See `CLAUDE.md` for the design.

```shell
forge build
forge test
```

## Mainnet fork suite

`test/fork/SYAHarvester.fork.t.sol` runs the full harvester against live mainnet state at a pinned
block (`MainnetAddresses.PINNED_BLOCK`, currently `26261000`). It needs an **archive-capable**
mainnet RPC in `MAINNET_RPC_URL` (`foundry.toml` maps it to the `mainnet` endpoint):

```shell
MAINNET_RPC_URL=<archive mainnet rpc> forge test --match-path test/fork/SYAHarvester.fork.t.sol -vv
```

Without `MAINNET_RPC_URL` the fork suite is reported as skipped and the unit suites still run.
The discovered Curve routes and the native-ETH/USDC V4 pool key live in
`test/fork/MainnetRoutes.sol` (`MainnetRoutes.configure(harvester)` registers them all).

## Operator script: `script/harvest.sh`

Harvests safely: it simulates `harvest` **with real fee fields**, derives a `minEthOut` that covers the gas,
and submits through a private relay so a transaction that would revert is never included on-chain.

### Prerequisites

Foundry (`cast`) plus `bash` and `bc`. No Node toolchain.

**Keys come only from a Foundry keystore.** Import the operator key once (the key and password are prompted,
never typed on the command line):

```shell
cast wallet import harvester-operator --interactive
```

The script refuses raw keys outright: `--private-key`, `--mnemonic`, `--interactive`, and the
`ETH_PRIVATE_KEY` / `PRIVATE_KEY` / `ETH_MNEMONIC` / `MNEMONIC` environment variables all abort it before
anything is sent. The keystore password is read from `KEYSTORE_PASSWORD_FILE` if set, otherwise `cast`
prompts for it (hidden). The script never prints it. Without `OPERATOR` set, the keystore is unlocked once
to derive the operator address and again by `cast send`, so expect two prompts unless you use a password file.

**Claim NFT approval.** With today's live SYA every claim burns one claim NFT, so `NFT_INDEX` must be a
non-zero index you hold (index 0 reverts `"Invalid index"`). Approve the harvester on the NFTMinter once:

```shell
cast send 0x39Af088408e815844c567037C157B31d48d2E10F "setApprovalForAll(address,bool)" <HARVESTER> true \
  --account harvester-operator --rpc-url "$MAINNET_RPC_URL"
```

`NFT_INDEX=0` (no NFT) only works after SYA's NFT gating is switched off.

### Inputs

Every input is an environment variable, and each has a flag that overrides it (`script/harvest.sh --help`).

| Env var | Flag | Meaning | Default |
|---|---|---|---|
| `HARVESTER` | `--harvester` | SYAHarvester address | required |
| `EXEMPT_STRATEGIES` | `--exempt` | comma-separated strategy addresses to exempt | empty |
| `NFT_INDEX` | `--nft-index` | claim NFT index (0 = none, post gating-off only) | required |
| `SLIPPAGE_BPS` | `--slippage-bps` | haircut on the simulated `ethOut` | `50` |
| `MIN_PROFIT_WEI` | `--min-profit-wei` | profit floor above the gas bound | `0` |
| `GAS_LIMIT_MARGIN_BPS` | `--gas-limit-margin-bps` | margin on the gas estimate | `2000` (20%) |
| `PRIORITY_FEE_WEI` | `--priority-fee-wei` | tip in wei, or `auto` for `eth_maxPriorityFeePerGas` | `1000000000` (1 gwei) |
| `MAINNET_RPC_URL` / `ETH_RPC_URL` | `--rpc-url` | read RPC for estimation and simulation | required |
| `PRIVATE_RPC_URL` | `--private-rpc-url` | submission relay | `https://rpc.flashbots.net` |
| `KEYSTORE_ACCOUNT` | `--account` | Foundry keystore account name | required to send |
| `KEYSTORE_PASSWORD_FILE` | `--password-file` | keystore password file | unset (prompt) |
| `OPERATOR` | `--operator` | sender address; must match the keystore when sending | derived from keystore |
| `RECEIPT_TIMEOUT` | `--receipt-timeout` | seconds `cast send` waits for the receipt | `600` |
| `RPC_TIMEOUT` | `--rpc-timeout` | per-request RPC timeout in seconds | `120` |
| `DRY_RUN` | `--dry-run` | stop after computing `minEthOut` | `0` |

```shell
# Look first
HARVESTER=0x... NFT_INDEX=1 KEYSTORE_ACCOUNT=harvester-operator MAINNET_RPC_URL=<rpc> DRY_RUN=1 script/harvest.sh
# Then send
HARVESTER=0x... NFT_INDEX=1 KEYSTORE_ACCOUNT=harvester-operator MAINNET_RPC_URL=<rpc> script/harvest.sh
```

### What it does

1. **Fees.** Reads the latest base fee and sets `maxFeePerGas = 2 * baseFee + PRIORITY_FEE_WEI`.
2. **Estimate.** `cast estimate` of `harvest(exempt, nftIndex, 0)` from the operator with both fee fields set,
   then `gasLimit = estimate * (10000 + GAS_LIMIT_MARGIN_BPS) / 10000`.
3. **Simulate.** `cast call` of the same call from the operator with the same fee fields and `gasLimit`, and
   decodes `ethOut`.
4. **`minEthOut`** `= max(ethOut * (10000 - SLIPPAGE_BPS) / 10000, gasLimit * maxFeePerGas + MIN_PROFIT_WEI)`,
   in integer wei (`bc`). If that exceeds `ethOut`, it aborts with "not profitable after gas and margin" and
   prints the numbers. This is conservative, since `maxFeePerGas` overstates the real price paid.
5. **Send.** Unless `DRY_RUN=1`, it runs `cast send` to `PRIVATE_RPC_URL` with `--account`, the gas limit and
   both fee fields, then prints the tx hash and receipt status. The script exits non-zero unless the status is 1.

Every computed value is printed before anything is sent. Any simulated revert aborts with the reason decoded
by name, for example `Unprofitable(ethOut, gasCost)`, `InsufficientEthOut(ethOut, minEthOut)` or
`RouteNotConfigured(token)`. `Error(string)` reasons such as `"Invalid index"` are passed through.

**Why the simulation carries fee fields.** The contract's gas check is
`(gasUsed + GAS_OVERHEAD) * tx.gasprice`. Wallets usually simulate at gas price 0, where that check passes
trivially. The script simulates and estimates with `--gas-price` and `--priority-gas-price` set, so
`tx.gasprice` is non-zero and the on-chain `Unprofitable` check really runs. The Anvil test proves this: at a
10 gwei tip the simulation reverts `Unprofitable`.

**Private relay.** By default the transaction goes through Flashbots Protect (`https://rpc.flashbots.net`),
which keeps it out of the public mempool and does not include transactions that would revert. Override it with
`PRIVATE_RPC_URL` (any relay or RPC that accepts `eth_sendRawTransaction` and answers `eth_chainId`,
`eth_getTransactionCount` and `eth_getTransactionReceipt`). The script aborts if the relay's chain id differs
from the read RPC's.

### Anvil-fork test

`test/script/harvest_anvil.sh` starts anvil on a mainnet fork at `MainnetAddresses.PINNED_BLOCK`. It deploys
a harvester configured with the story-004 routes and V4 pool key (`test/script/DeployHarvesterForTest.s.sol`,
test-only), gives the operator a claim NFT and the approval, and creates the operator as a fresh random key in
a **temporary** keystore under a throwaway `HOME`. It then drives the script through these cases:

- a raw key in the environment, which is refused;
- `MIN_PROFIT_WEI` too high, which aborts before sending;
- a 10 gwei tip, where the on-chain `Unprofitable` fires in simulation;
- a cleared DOLA route, which aborts with `RouteNotConfigured`;
- `DRY_RUN`;
- a profitable send, where the operator's ETH rises and the harvester ends holding nothing.

Every abort case asserts that the operator's nonce is unchanged.

```shell
MAINNET_RPC_URL=<archive mainnet rpc> test/script/harvest_anvil.sh   # ~2.5 min; ANVIL_PORT defaults to 8546
```

Without `MAINNET_RPC_URL` it prints `SKIPPED` and exits 77, which never counts as a pass.
