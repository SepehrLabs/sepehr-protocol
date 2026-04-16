# AEGIS Contracts

Solidity smart contracts for the AEGIS liquidation protection protocol.

## Contracts

| Contract | Description |
|----------|-------------|
| `AegisCore.sol` | Subscription management, protection config, trigger execution |
| `AegisTimelock.sol` | Time-locked admin operations |

### Protocol Adapters
Aave V3, Aave V4, Compound V2, Compound V3, Morpho Blue, Euler V2, Fluid, Curve Llamalend, Gearbox, Maker

### Flash Loan Providers
Aave, Balancer, Uniswap V3

### DEX Routers
Uniswap V3, Uniswap V2 forks, Velodrome, Camelot, Trader Joe V2.2

## Commands

```bash
forge build              # Compile
forge test -vv           # Run all tests
forge fmt                # Format
forge fmt --check        # Check formatting (CI)
```

## Deployment

```bash
source ../.env
forge script script/DeployCore.s.sol \
  --rpc-url $RPC_ETHEREUM_PRIMARY_HTTP \
  --broadcast --verify
```

## Test Structure

```
test/
├── unit/           # Unit tests with mock contracts
│   ├── AegisCore.Admin.t.sol
│   ├── AegisCore.Subscriptions.t.sol
│   ├── AegisCore.Triggers.t.sol
│   ├── adapters/   # Per-adapter unit tests
│   ├── dex/        # DEX router tests
│   ├── flash/      # Flash provider tests
│   └── libraries/  # Math library tests
├── fork/           # Fork tests against mainnet protocols
└── invariant/      # Invariant/fuzz testing
```
