# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

SYAHarvester is a flash-loan helper that claims from `StableYieldAccumulator` (SYA, sibling repo
`../stable-yield-accumulator`) and pays the profit to the caller in ETH. The caller spends only gas,
and the contract refuses to complete unless the ETH returned covers that gas.

SYA sells its pending yield-strategy rewards (USDe, DOLA, ...) at a discount in exchange for its
reward token (USDC). A claim therefore has positive expected value whenever
`market value of the yield tokens - discounted USDC payment > gas + NFT cost`. The harvester makes
that trade atomic:

1. Optionally pull one claim NFT (ERC1155) from the caller.
2. Open a Uniswap V4 `PoolManager.unlock` and `take` the USDC that SYA will pull.
3. Call `sya.claim(nftIndex, 0, exemptStrategies)`. SYA burns one NFT unit from the harvester,
   pushes the yield tokens to the harvester via `skimSurplus`, then pulls the USDC payment.
4. Sell every received yield token to USDC along a stored, owner-registered route.
5. Swap the USDC surplus to native ETH in a V4 pool, settle the USDC debt, `take` the ETH.
6. Refund any NFT units that were not burned, check profitability, and send the ETH to `msg.sender`.

## Design decisions (settled — do not relitigate in a story)

- **Flash source is Uniswap V4 `unlock` flash accounting.** It is free, and the callback can only
  ever be delivered to the contract that called `unlock`, so `msg.sender == poolManager` is the
  whole access check. Balancer is not used (it is being wound down); Morpho is not used.
- **Nested unlock hazard.** While inside `unlockCallback` the PoolManager is already unlocked; any
  code that calls `unlock` again (Universal Router, V4-based aggregators, possibly a yield
  strategy's `skimSurplus`) reverts `AlreadyUnlocked`. Route steps that touch V4 must call
  `poolManager.swap` directly. Fork tests must prove the live SYA strategies do not nest.
- **Routes are stored on-chain, keyed by token**, as an ordered list of steps (Curve stableswap-ng,
  Curve crypto, Uniswap V4 direct swap, ERC4626 redeem). Each step swaps the harvester's entire
  balance of its input token, so no amounts are passed in calldata. Routes are owner-settable.
- **One slippage check.** The call is atomic, so the only number that protects the caller is the
  ETH they receive: a single `minEthOut`. There are no per-token minimums. SYA's own
  `minRewardTokenSupplied` is passed as 0.
- **Route coverage invariant** (lesson from the removed `ClaimArbitrage`, audit M-01): every
  non-exempt SYA strategy token must have a registered route, otherwise the harvest reverts rather
  than stranding tokens in the contract.
- **Reward-token skip.** If a strategy pays out SYA's reward token itself, no swap is needed. Read
  `sya.rewardToken()` at run time; never hard-code USDC as "the token to skip".
- **Borrow size** is `sya.calculateClaimAmount(exemptStrategies)` read inside the callback, plus a
  small buffer. Over-borrowing is free and the excess is simply settled back.
- **NFT handling.** `nftIndex == 0` means "do not transfer an NFT" (SYA itself rejects index 0, so
  the sentinel is safe). When non-zero, pull exactly one unit; after the unlock, return the
  harvester's whole remaining balance of that index to the caller. Today SYA always burns or
  reverts, so the refund never fires; it exists for when NFT gating is switched off.
- **Gas check.** Measure `gasleft()` at entry and before payout, add a constant `GAS_OVERHEAD` for
  intrinsic/calldata/payout gas, multiply by `tx.gasprice`, and revert `Unprofitable` if the ETH out
  is below it. Note: wallet simulations usually run with gas price 0, which makes this check pass
  trivially in simulation. Off-chain tooling must simulate with fee fields set.
- **Public, stateless between calls.** Anyone may call `harvest`; all profit goes to `msg.sender`.
  The contract holds no balances between calls.

## Dependencies

Plain git submodules under `lib/`, wired through `remappings.txt` and `foundry.toml` (keep both in
sync, matching the sibling repos):

- `forge-std` (present)
- Added by stories as needed: `openzeppelin-contracts` (v5.1.0, matching SYA), `v4-core` (v4.0.0,
  matching SYA's lock), and `stable-yield-accumulator` for `IStableYieldAccumulator`.

## Development Guidelines

All work follows TDD: write failing tests first (RED), make them pass (GREEN), then refactor.
Fork tests read `MAINNET_RPC_URL` from the environment (see `[rpc_endpoints]` in `foundry.toml`).

- `forge build`
- `forge test` / `forge test -vvv` / `forge test --match-test <name>`
- `forge test --fork-url $MAINNET_RPC_URL` for fork suites
- `forge snapshot`
