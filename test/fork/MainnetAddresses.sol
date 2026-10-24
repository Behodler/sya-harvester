// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MainnetAddresses
/// @notice Ethereum mainnet addresses the harvester fork suite (story 004) and the operator script
///         (story 005) use. Every address is re-verified on the fork by `SYAHarvesterForkTest`.
/// @dev Provenance:
///      - "mainnet-addresses.ts" = `phase-2-staging/server/deployments/mainnet-addresses.ts` (read-only).
///      - "archive scripts" = `phase-2-staging/script/archives/*` (MigrateStableStakerMainnet,
///        DeployUSDeMarketYieldStrategy) and the vault `CurveAMMAdapter` precedent.
///      - "fork" = discovered or confirmed on the fork at `PINNED_BLOCK`.
///      The fork-time `sya.getYieldStrategies()` / `sya.strategyTokens(s)` are the source of truth; at
///      `PINNED_BLOCK` they match the three strategies below exactly (no difference from the table).
library MainnetAddresses {
    /// @notice Recent mainnet block the fork suite pins (2026-10-24, timestamp 1792826807)
    uint256 internal constant PINNED_BLOCK = 26_261_000;

    // --- Phoenix (mainnet-addresses.ts) ---
    address internal constant SYA = 0x0cD353bfda674D04823B2826ffafB83B560D21B6;
    /// @dev Pays USDC (SYA's reward token) itself, so it needs no route (reward-token skip)
    address internal constant YS_USDC = 0xaFDf8DeA96a0F37Aae4869f813901bf73a3eAB83;
    /// @dev ERC4626Market strategy; its skimSurplus swaps sUSDe -> USDe via CurveAMMAdapter -> Router NG
    address internal constant YS_USDE = 0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95;
    /// @dev sDOLA strategy
    address internal constant YS_DOLA = 0x981c7BE1460c7C8Cb40B8EB5908B29510Ae0B7EE;
    /// @dev NFTMinterV2 (ERC1155) — SYA's claim-NFT gate
    address internal constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;
    /// @dev For reference only: the USDe strategy's CurveAMMAdapter
    address internal constant USDE_AMM_ADAPTER = 0x2D024e0d03Fb6Ead4F8E7Ba1EBECF6db0E755D6f;

    // --- Tokens ---
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // mainnet-addresses.ts
    address internal constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4; // mainnet-addresses.ts
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3; // mainnet-addresses.ts
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E; // archive scripts
    address internal constant FRAX = 0x853d955aCEf822Db058eb8505911ED77F175b99e; // fork (FRAXBP coin0)

    // --- Curve (archive scripts / fork) ---
    address internal constant CURVE_ROUTER_NG = 0x16C6521Dff6baB339122a0FE25a9116693265353; // archive scripts
    /// @dev Curve MetaRegistry, used on the fork to discover the crvUSD/USDC and DOLA pools
    address internal constant CURVE_META_REGISTRY = 0xF98B45FA17DE75FB1aD0e7aFD971b0ca00e379fC; // fork

    // --- Uniswap V4 (verified on the fork: has code, `unlock` behaves as v4, StateView agrees) ---
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    /// @dev Uniswap V4 StateView; its `poolManager()` returns `POOL_MANAGER` on the fork
    address internal constant V4_STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;

    // --- Claim NFT source (fork) ---
    /// @dev EOA holding exactly 1 unit of NFT index 1 at `PINNED_BLOCK` (found from TransferSingle logs;
    ///      the larger holders of every index are contracts). The suite pranks it to transfer that unit.
    address internal constant NFT_HOLDER = 0x025494682Fb33792145F1a459555C7000BaB53C4;
    uint256 internal constant NFT_INDEX = 1;
}
