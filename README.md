# Sepehr Protocol — Contracts

Solidity smart contracts for the Sepehr liquidation protection protocol.

Sepehr is a non-custodial protocol that monitors lending positions and
executes flash-loan-backed repayments when a user-defined health
factor threshold is breached. Users delegate authority to a flash
rescue path; Sepehr never custodies collateral.

## Scope

**V1 mainnet:** Arbitrum One (chain id `42161`). Testnet: Arbitrum
Sepolia (chain id `421614`). Three adapters are registered via
`SepehrCore.addAdapter` in V1 and constitute the entire active
protocol surface: Aave V3, Compound V3, Morpho Blue.

## Contracts

| Contract | Description |
|----------|-------------|
| `src/SepehrCore.sol` | Subscription management, protection config, trigger execution |
| `src/SepehrTimelock.sol` | OpenZeppelin TimelockController wrapper for admin operations |

### Protocol adapters (`src/adapters/`)

Aave V3, Compound V3, Morpho Blue. All implement `IProtocolAdapter`.

### Flash loan providers (`src/flash/`)

Aave, Balancer, Uniswap V3. All implement `IFlashLoanProvider`.

### DEX routers (`src/dex/`)

Uniswap V3, Uniswap V2 forks, Velodrome, Camelot, Trader Joe V2.2.
All implement `IDexRouter`.

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
`RPC_ARBITRUM_SEPOLIA_PRIMARY_HTTP` in `.env`.

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
(42161) or Arbitrum Sepolia (421614).

```bash
source .env
forge script script/DeployCore.s.sol \
  --rpc-url $RPC_ARBITRUM_SEPOLIA_PRIMARY_HTTP \
  --broadcast --verify
```

## Audit

External audit pending. Internal review complete. Deployments are
governed by a 48-hour `TimelockController`.

## Licensing

| Path | License |
|------|---------|
| `src/SepehrCore.sol`, `src/SepehrTimelock.sol`, `src/adapters/`, `src/dex/`, `src/flash/` | [BUSL 1.1](LICENSE) → MIT on 2030-04-21 |
| `src/libraries/`, `src/mocks/` | MIT |
| `src/interfaces/` | GPL-2.0-or-later |
| `test/`, `script/` | MIT |

For Additional Use Grants under BUSL 1.1, see
[`docs/legal/additional-use-grants.md`](docs/legal/additional-use-grants.md).

## Security

Report vulnerabilities to **security@sepehr.app** (PGP key at
[`docs/security/sepehr-pgp.asc`](docs/security/sepehr-pgp.asc)).
See [`SECURITY.md`](SECURITY.md) for full policy and scope.
