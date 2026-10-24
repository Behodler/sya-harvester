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
