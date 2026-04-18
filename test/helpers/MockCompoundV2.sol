// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ICToken, ICompoundOracle, IComptroller} from "../../src/interfaces/external/ICToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Compound V2 Oracle for unit testing CompoundV2Adapter.
contract MockCompoundOracle is ICompoundOracle {
    mapping(address => uint256) private _prices;

    function setUnderlyingPrice(
        address cToken,
        uint256 price
    ) external {
        _prices[cToken] = price;
    }

    function getUnderlyingPrice(
        address cToken
    ) external view returns (uint256) {
        return _prices[cToken];
    }
}

/// @notice Mock Compound V2 Comptroller for unit testing CompoundV2Adapter.
contract MockComptroller is IComptroller {
    struct Liquidity {
        uint256 err;
        uint256 liquidity;
        uint256 shortfall;
    }

    mapping(address => Liquidity) private _liquidity;
    mapping(address => address[]) private _assetsIn;
    address private _oracle;

    function setOracle(
        address oracle_
    ) external {
        _oracle = oracle_;
    }

    function setAccountLiquidity(
        address user,
        uint256 err,
        uint256 liquidity,
        uint256 shortfall
    ) external {
        _liquidity[user] = Liquidity(err, liquidity, shortfall);
    }

    function getAccountLiquidity(
        address account
    ) external view returns (uint256 err, uint256 liquidity, uint256 shortfall) {
        Liquidity storage l = _liquidity[account];
        return (l.err, l.liquidity, l.shortfall);
    }

    function oracle() external view returns (address) {
        return _oracle;
    }

    function setAssetsIn(
        address user,
        address[] calldata assets
    ) external {
        delete _assetsIn[user];
        for (uint256 i = 0; i < assets.length; ++i) {
            _assetsIn[user].push(assets[i]);
        }
    }

    function getAssetsIn(
        address account
    ) external view returns (address[] memory) {
        return _assetsIn[account];
    }
}

/// @notice Mock Compound V2 cToken (ERC20-based) for unit testing CompoundV2Adapter.
contract MockCToken is ERC20, ICToken {
    address private _underlying;
    uint256 private _exchangeRate;

    mapping(address => uint256) private _borrowBalance;

    address public lastRepayBorrower;
    uint256 public lastRepayAmount;
    uint256 public lastRedeemAmount;

    constructor(
        string memory name_,
        string memory symbol_,
        address underlying_
    ) ERC20(name_, symbol_) {
        _underlying = underlying_;
        _exchangeRate = 2e17; // 0.2 by default (1 cToken = 0.2 underlying)
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function setExchangeRate(
        uint256 rate
    ) external {
        _exchangeRate = rate;
    }

    // ── ICToken implementation ───────────────────────────────────────────

    function underlying() external view returns (address) {
        return _underlying;
    }

    function exchangeRateCurrent() external returns (uint256) {
        // In real Compound this is non-view; mock just returns stored value.
        return _exchangeRate;
    }

    function exchangeRateStored() external view returns (uint256) {
        return _exchangeRate;
    }

    function repayBorrowBehalf(
        address borrower,
        uint256 repayAmount
    ) external returns (uint256) {
        lastRepayBorrower = borrower;
        lastRepayAmount = repayAmount;
        IERC20(_underlying).transferFrom(msg.sender, address(this), repayAmount);
        return 0; // 0 means success in Compound
    }

    function redeemUnderlying(
        uint256 redeemAmount
    ) external returns (uint256) {
        lastRedeemAmount = redeemAmount;
        IERC20(_underlying).transfer(msg.sender, redeemAmount);
        return 0; // 0 means success in Compound
    }

    function balanceOf(
        address account
    ) public view override(ERC20, ICToken) returns (uint256) {
        return super.balanceOf(account);
    }

    function balanceOfUnderlying(
        address owner
    ) external view returns (uint256) {
        return balanceOf(owner) * _exchangeRate / 1e18;
    }

    function borrowBalanceCurrent(
        address
    ) external pure returns (uint256) {
        return 0;
    }

    function setBorrowBalance(
        address borrower,
        uint256 amount
    ) external {
        _borrowBalance[borrower] = amount;
    }

    function borrowBalanceStored(
        address account
    ) external view returns (uint256) {
        return _borrowBalance[account];
    }
}
