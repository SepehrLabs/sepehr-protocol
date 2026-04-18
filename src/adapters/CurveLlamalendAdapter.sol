// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {ICurveController} from "../interfaces/external/ICurveLlamma.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CurveLlamalendAdapter
/// @notice Protocol adapter for Curve Lending (crvUSD / LLAMMA) positions. Translates
///         Curve's health metric to a standard health factor and handles repayment.
contract CurveLlamalendAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    ICurveController public immutable CONTROLLER;
    address public immutable PRICE_ORACLE;
    address public immutable core;

    modifier onlyCore() {
        if (msg.sender != core) revert SepehrErrors.NotAuthorized();
        _;
    }

    constructor(
        address controller,
        address priceOracle,
        address _core
    ) {
        if (controller == address(0)) revert SepehrErrors.ZeroAddress();
        if (priceOracle == address(0)) revert SepehrErrors.ZeroAddress();
        if (_core == address(0)) revert SepehrErrors.ZeroAddress();
        CONTROLLER = ICurveController(controller);
        PRICE_ORACLE = priceOracle;
        core = _core;
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Curve's `health` is a WAD-scaled additive margin relative to the
    ///      liquidation boundary: `collateralEquiv / debt - 1`. So the canonical
    ///      HF in our scale is `HF_WAD = 1e18 + health`. Clamp at 0 when the
    ///      margin has fallen to or past -100% (health <= -1e18).
    ///      Audit B6: the prior `1e18 + uint256(health)` branch had no
    ///      handling for negative health and collapsed the whole range to 0.
    ///      Audit B18: short-circuit zero-debt positions to `type(uint256).max` so the
    ///      empty-position semantics match Aave/Morpho/Euler/Compound V3/Maker/Gearbox. Without
    ///      this guard Curve's `health()` may revert on unopened loans, which would corrupt
    ///      keeper batch monitoring that treats `max` as "no debt, nothing to do".
    function getHealthFactor(
        address user
    ) external view returns (uint256 healthFactor) {
        uint256[4] memory state = CONTROLLER.user_state(user);
        if (state[2] == 0) return type(uint256).max;
        int256 health = CONTROLLER.health(user);
        if (health <= -1e18) return 0;
        return uint256(int256(1e18) + health);
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Curve LLAMMA does not expose a per-spender delegation primitive: `repay` and
    ///      `remove_collateral` operate on `msg.sender`'s own position. A third-party adapter
    ///      cannot legitimately act on a user's behalf without ownership transfer, so this
    ///      check returns `false` to make the constraint enforceable in `enableProtection`.
    ///      Until a delegation pathway is added on Curve's side, the adapter cannot be enabled
    ///      for live protection.
    function checkDelegation(
        address /* user */
    ) external pure returns (bool delegated) {
        return false;
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B12: sweep residual `debtAsset` after `repay`, which caps at the user's
    ///      outstanding debt and may leave a surplus in the adapter.
    ///      Audit B17: Curve LLAMMA controllers borrow a single known `borrowed_token` (crvUSD
    ///      on mainnet). Reject any other `debtAsset` before touching approvals to avoid
    ///      stranding a stale approval on a token Curve will never pull.
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        address expected = CONTROLLER.borrowed_token();
        if (debtAsset != expected) {
            revert SepehrErrors.DebtAssetMismatch(expected, debtAsset);
        }
        IERC20(debtAsset).forceApprove(address(CONTROLLER), amount);
        CONTROLLER.repay(amount, user);
        uint256 surplus = IERC20(debtAsset).balanceOf(address(this));
        if (surplus > 0) {
            IERC20(debtAsset).safeTransfer(core, surplus);
        }
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B21: the prior implementation transferred `balanceOf(this)` to the recipient,
    ///      which would sweep any pre-existing donation sitting on the adapter into the trigger's
    ///      caller. Snapshot the balance before `remove_collateral` and transfer only the delta
    ///      pulled in by this call. This also makes the path robust to fee-on-transfer
    ///      collateral tokens (the recipient receives whatever Curve actually paid out).
    function withdrawCollateral(
        address user,
        address,
        uint256 amount,
        address recipient
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        if (recipient == address(0)) revert SepehrErrors.ZeroAddress();
        address collateralToken = CONTROLLER.collateral_token();
        uint256 balanceBefore = IERC20(collateralToken).balanceOf(address(this));
        // remove_collateral is owner-only in Curve. The adapter calls it, and the
        // controller checks that msg.sender owns the position or is authorized.
        CONTROLLER.remove_collateral(amount);
        uint256 received = IERC20(collateralToken).balanceOf(address(this)) - balanceBefore;
        if (received > 0) {
            IERC20(collateralToken).safeTransfer(recipient, received);
        }
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev user_state returns [collateral, stablecoin, debt, N] in raw base
    ///      units of each token. The raw collateral amount must be priced
    ///      through Curve's WAD-scaled `price_oracle()` before it can be summed
    ///      with the stablecoin (crvUSD ≈ $1, 18 dec). Output is USD-8 to
    ///      match tier-cap accounting. Audit B7: the prior `(stab + coll) /
    ///      1e10` summed token units across different assets without pricing,
    ///      reporting nonsense values (a $500k WETH position as $500 billion).
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        uint256[4] memory state = CONTROLLER.user_state(user);
        uint256 collateral = state[0];
        uint256 stablecoin = state[1];
        if (collateral == 0 && stablecoin == 0) return 0;
        uint256 price = CONTROLLER.price_oracle(); // WAD: USD per collateral token
        uint256 collateralUsd18 = collateral * price / 1e18;
        return (collateralUsd18 + stablecoin) / 1e10;
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Reads LLAMMA's `user_state` (index 2 = debt). Returns 0 unless `debtAsset` matches
    ///      the controller's borrowed token (crvUSD on mainnet).
    function getDebt(
        address user,
        address debtAsset
    ) external view returns (uint256 debt) {
        if (debtAsset != CONTROLLER.borrowed_token()) return 0;
        uint256[4] memory state = CONTROLLER.user_state(user);
        return state[2];
    }
}
