# sya-harvester

Flash-loan helper that claims discounted yield from `StableYieldAccumulator`, sells it, repays the
flash loan, and returns the surplus to the caller as ETH. See `CLAUDE.md` for the design.

```shell
forge build
forge test
```
