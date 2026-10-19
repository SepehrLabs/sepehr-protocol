# Sepehr Protocol — Contracts

Solidity smart contracts for Sepehr, non-custodial liquidation protection for
DeFi lending positions on Arbitrum.

An owner protects a position by choosing two health factors: the threshold
where Sepehr steps in and the target it brings the position back to. When the
position falls under its threshold, a keeper calls `SepehrCore.execute`, which
repays part of the debt in a single transaction: first from a budget the owner
approved in their wallet, otherwise with a flash loan against the collateral.
If any step fails, the whole transaction reverts. An owner can also set a
stop-loss or take-profit that closes the whole position at an oracle price.

Sepehr never holds collateral: the owner grants an authorization on the lending
protocol, usable only to rescue or close a position they protected, and can
revoke it at any time.

- Website: [sepehr.app](https://sepehr.app)
- App (testnet): [app.sepehr.app](https://app.sepehr.app)
- Tester guide: [sepehr.app/testnet](https://sepehr.app/testnet)

## Scope

**V1 mainnet:** Arbitrum One (chain id `42161`). **Testnet:** Arbitrum Sepolia
(chain id `421614`), live now. Three protocols are registered in V1: Aave V3,
Compound V3 and Morpho Blue.

## Contracts

| Contract | Description |
|----------|-------------|
| `src/SepehrCore.sol` | Protection settings, rescues (`execute`), stop-loss and take-profit (`setExitOrder`, `close`), fees, registries of adapters, keepers, oracles, routers and flash providers |
| `src/SepehrSubscriptions.sol` | Plans paid in USDC: subscribe, renew, upgrade, cancel with refund; each paid window is earned pro rata; Titan grants |
| `src/SepehrTimelock.sol` | OpenZeppelin `TimelockController` wrapper (48 hours) for every admin change |

### Guardrails enforced on-chain

- A rescue repays at most half of the debt, and must leave the health factor
  above where it was and no more than 0.05 above the owner's target.
- Collateral is never sold below the oracle price minus the owner's maximum
  price impact.
- Plan prices move at most ±50 % per change, once every 7 days; rescue fees
  are capped at 1 %.
- Every admin change goes through the 48-hour timelock; only the emergency
  pause, which stops rescues, is immediate.

### Protocol adapters (`src/adapters/`)

Aave V3 (every collateral of the owner), Compound V3, Morpho Blue. All
implement `IProtocolAdapter`.

### Flash loan providers (`src/flash/`)

Aave, Balancer, Morpho Blue, Uniswap V3. All implement `IFlashLoanProvider`;
the keeper passes the available ones cheapest first.

### DEX routers (`src/dex/`)

- `UniswapV3Router`: single pool or multi-hop path; the router whitelisted
  in V1.
- `AggregatorRouter`: replays KyberSwap or Velora calldata against a target,
  spender and set of functions fixed at deployment (`AggregatorSelectors`),
  measures its output against the core's minimum, and returns the input left
  unsold. One instance per aggregator, deployed with mainnet.
- Uniswap V2 forks, Velodrome, Camelot, Trader Joe V2.2: kept for later chains,
  not registered in V1.

All implement `IDexRouter`.

### Oracles (`src/oracles/`)

`ChainlinkProductFeed`: the product of two Chainlink feeds, for an asset priced
through another (wstETH/USD from wstETH/ETH and ETH/USD).

### Mocks (`src/mocks/`, `test/helpers/Mock*.sol`)

Test utilities used to exercise the protocol in isolation. They are
not part of the production deployment and are explicitly out of
scope for any external audit, per standard DeFi convention (cf.
Morpho Blue, Aave V3 Core).

## Build and test

```bash
forge install            # Fetch forge-std and openzeppelin-contracts
forge build              # Compile (Solidity 0.8.28, via_ir, Cancun)
forge test -vv           # Unit + fork + invariant tests
forge fmt                # Format
forge fmt --check        # Check formatting (CI)
```

Fork tests require RPC endpoints. Set `RPC_ARBITRUM_PRIMARY_HTTP` and
`RPC_ARBITRUM_SEPOLIA_PRIMARY_HTTP` in `.env`; without them they are skipped.

## Test structure

```
test/
├── unit/         # Mock-based unit tests
├── fork/         # Fork tests against live protocols
├── invariant/    # Stateful fuzzing
├── integration/  # Cross-contract integration scenarios
└── helpers/      # Mock contracts and test utilities
```

## Deployment

V1 deploy scripts abort on any chain id other than Arbitrum One
(42161) or Arbitrum Sepolia (421614). On Arbitrum One, `DeployCore`
refuses an owner that is not a Safe requiring 2 of at least 3 signers.

### Arbitrum Sepolia (testnet)

| Contract | Address |
|----------|---------|
| SepehrCore | `0x362AA845dEBa9F7458996f4C89235a2a245F3c0C` |
| SepehrSubscriptions | `0xb8406EC69EAe5dB26EDFb67F62F92ef3245a4Cbe` |
| Timelock (5 minutes on the testnet) | `0x036F1c4d2006442a020C98eabb6216c880CCd054` |
| Aave V3 adapter | `0x255756AF613110529400bcaaDFc2b8D4008401b7` |

The full list is in [`deployments/arbitrum-sepolia-v2.json`](deployments/arbitrum-sepolia-v2.json).

## Audit

Internal review complete. A public audit contest comes before mainnet,
then a bug bounty. Until then, only test tokens are at stake.

## Licensing

| Path | License |
|------|---------|
| `src/SepehrCore.sol`, `src/SepehrSubscriptions.sol`, `src/SepehrTimelock.sol`, `src/adapters/`, `src/dex/`, `src/flash/`, `src/oracles/` | [BUSL 1.1](LICENSE) → MIT on 2030-04-21 |
| `src/libraries/`, `src/mocks/` | MIT |
| `src/interfaces/` | GPL-2.0-or-later |
| `test/`, `script/` | MIT |

For Additional Use Grants under BUSL 1.1, see
[`docs/legal/additional-use-grants.md`](docs/legal/additional-use-grants.md).

## Security

Report vulnerabilities to **security@sepehr.app** (PGP key at
[`docs/security/sepehr-pgp.asc`](docs/security/sepehr-pgp.asc)).
See [`SECURITY.md`](SECURITY.md) for full policy and scope.
