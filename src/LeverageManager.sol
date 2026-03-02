// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolAddressesProvider} from "@aave/v3-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@aave/v3-core/contracts/interfaces/IPool.sol";
import {IFlashLoanSimpleReceiver} from "@aave/v3-core/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import {DataTypes} from "@aave/v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {ILeverageManager} from "./interfaces/ILeverageManager.sol";
import {SwapHelper} from "./libraries/SwapHelper.sol";

contract LeverageManager is IFlashLoanSimpleReceiver, ILeverageManager, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SwapHelper for ISwapRouter;

    struct CallbackData {
        Operation operation;
        address user;
        address collateralAsset;
        address debtAsset;
        uint256 collateralToWithdraw;
        uint24 swapPoolFee;
        uint16 slippageBps;
        bytes swapPath;
    }

    IPoolAddressesProvider public immutable override ADDRESSES_PROVIDER;
    IPool public immutable override POOL;
    ISwapRouter public immutable SWAP_ROUTER;

    constructor(IPoolAddressesProvider addressesProvider, ISwapRouter swapRouter) {
        ADDRESSES_PROVIDER = addressesProvider;
        POOL = IPool(addressesProvider.getPool());
        SWAP_ROUTER = swapRouter;
    }

    // ──────────────────────────────────────────────
    // External entry points
    // ──────────────────────────────────────────────

    function leverageUp(LeverageParams calldata params) external nonReentrant {
        bytes memory cbData = abi.encode(
            CallbackData({
                operation: Operation.LEVERAGE_UP,
                user: msg.sender,
                collateralAsset: params.collateralAsset,
                debtAsset: params.debtAsset,
                collateralToWithdraw: 0,
                swapPoolFee: params.swapPoolFee,
                slippageBps: params.slippageBps,
                swapPath: params.swapPath
            })
        );

        POOL.flashLoanSimple(address(this), params.debtAsset, params.flashLoanAmount, cbData, 0);
    }

    function deleverage(DeleverageParams calldata params) external nonReentrant {
        // aToken transfer happens inside the callback AFTER debt repayment
        // to avoid health factor revert when withdrawing all collateral

        bytes memory cbData = abi.encode(
            CallbackData({
                operation: Operation.DELEVERAGE,
                user: msg.sender,
                collateralAsset: params.collateralAsset,
                debtAsset: params.debtAsset,
                collateralToWithdraw: params.collateralToWithdraw,
                swapPoolFee: params.swapPoolFee,
                slippageBps: params.slippageBps,
                swapPath: params.swapPath
            })
        );

        POOL.flashLoanSimple(address(this), params.debtAsset, params.flashLoanAmount, cbData, 0);
    }

    // ──────────────────────────────────────────────
    // Flash loan callback
    // ──────────────────────────────────────────────

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == address(POOL), "LeverageManager: caller must be Pool");
        require(initiator == address(this), "LeverageManager: initiator must be this contract");

        CallbackData memory data = abi.decode(params, (CallbackData));

        if (data.operation == Operation.LEVERAGE_UP) {
            _executeLeverageUp(data, asset, amount, premium);
        } else {
            _executeDeleverage(data, asset, amount, premium);
        }

        // Approve Pool to pull back flash loan + premium
        uint256 totalOwed = amount + premium;

        // Sweep any excess debt tokens back to user (deleverage may produce surplus)
        uint256 assetBalance = IERC20(asset).balanceOf(address(this));
        if (assetBalance > totalOwed) {
            IERC20(asset).safeTransfer(data.user, assetBalance - totalOwed);
        }

        _forceApprove(asset, address(POOL), totalOwed);

        return true;
    }

    // ──────────────────────────────────────────────
    // Internal logic
    // ──────────────────────────────────────────────

    function _executeLeverageUp(
        CallbackData memory data,
        address asset,
        uint256 amount,
        uint256 premium
    ) internal {
        // 1. Swap debtAsset → collateralAsset
        uint256 collateralReceived;
        if (data.swapPath.length > 0) {
            collateralReceived = SWAP_ROUTER.exactInput(
                data.swapPath, amount, data.slippageBps
            );
        } else {
            collateralReceived = SWAP_ROUTER.exactInputSingle(
                asset, data.collateralAsset, data.swapPoolFee, amount, data.slippageBps
            );
        }

        // 2. Supply collateral to Aave on behalf of user
        _forceApprove(data.collateralAsset, address(POOL), collateralReceived);
        POOL.supply(data.collateralAsset, collateralReceived, data.user, 0);

        // 3. Borrow debtAsset on behalf of user to repay flash loan
        //    User must have granted credit delegation to this contract beforehand
        uint256 totalOwed = amount + premium;
        POOL.borrow(asset, totalOwed, 2, 0, data.user);

        emit LeveragedUp(data.user, data.collateralAsset, data.debtAsset, amount, collateralReceived);
    }

    function _executeDeleverage(
        CallbackData memory data,
        address asset,
        uint256 amount,
        uint256 premium
    ) internal {
        // 1. Repay user's debt with flash-borrowed tokens
        _forceApprove(asset, address(POOL), amount);
        uint256 debtRepaid = POOL.repay(asset, amount, 2, data.user);

        // 2. Transfer aTokens from user (safe now that debt is repaid, health factor OK)
        DataTypes.ReserveData memory reserveData = POOL.getReserveData(data.collateralAsset);
        IERC20(reserveData.aTokenAddress).safeTransferFrom(
            data.user, address(this), data.collateralToWithdraw
        );

        // 3. Withdraw collateral (burn aTokens held by contract)
        uint256 collateralWithdrawn = POOL.withdraw(
            data.collateralAsset, data.collateralToWithdraw, address(this)
        );

        // 3. Swap collateralAsset → debtAsset to repay flash loan
        if (data.swapPath.length > 0) {
            SWAP_ROUTER.exactInput(data.swapPath, collateralWithdrawn, data.slippageBps);
        } else {
            SWAP_ROUTER.exactInputSingle(
                data.collateralAsset, asset, data.swapPoolFee, collateralWithdrawn, data.slippageBps
            );
        }

        emit Deleveraged(data.user, data.collateralAsset, data.debtAsset, debtRepaid, collateralWithdrawn);

        // 4. Sweep remaining collateral back to user
        _sweepToken(data.collateralAsset, data.user);
    }

    function _sweepToken(address token, address to) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(to, balance);
        }
    }

    function _forceApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).safeApprove(spender, 0);
        if (amount > 0) {
            IERC20(token).safeApprove(spender, amount);
        }
    }
}
