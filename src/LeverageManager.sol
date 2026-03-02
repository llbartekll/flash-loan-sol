// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolAddressesProvider} from "@aave/v3-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@aave/v3-core/contracts/interfaces/IPool.sol";
import {IFlashLoanSimpleReceiver} from "@aave/v3-core/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import {DataTypes} from "@aave/v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
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
    IQuoter public immutable QUOTER;

    constructor(IPoolAddressesProvider addressesProvider, ISwapRouter swapRouter, IQuoter quoter) {
        require(address(addressesProvider) != address(0), "LeverageManager: invalid provider");
        require(address(swapRouter) != address(0), "LeverageManager: invalid router");
        require(address(quoter) != address(0), "LeverageManager: invalid quoter");
        ADDRESSES_PROVIDER = addressesProvider;
        POOL = IPool(addressesProvider.getPool());
        SWAP_ROUTER = swapRouter;
        QUOTER = quoter;
    }

    // ──────────────────────────────────────────────
    // External entry points
    // ──────────────────────────────────────────────

    function leverageUp(LeverageParams calldata params) external nonReentrant {
        _validateCommonParams(
            params.collateralAsset, params.debtAsset, params.flashLoanAmount, params.slippageBps
        );
        if (params.swapPath.length > 0) {
            _validatePath(params.swapPath, params.debtAsset, params.collateralAsset);
        } else {
            require(params.swapPoolFee > 0, "LeverageManager: invalid pool fee");
        }

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
        _validateCommonParams(
            params.collateralAsset, params.debtAsset, params.flashLoanAmount, params.slippageBps
        );
        require(params.collateralToWithdraw > 0, "LeverageManager: invalid withdraw amount");
        if (params.swapPath.length > 0) {
            _validatePath(params.swapPath, params.collateralAsset, params.debtAsset);
        } else {
            require(params.swapPoolFee > 0, "LeverageManager: invalid pool fee");
        }

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
        require(asset == data.debtAsset, "LeverageManager: callback asset mismatch");

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
            uint256 minOut = _quoteMinOutPath(data.swapPath, amount, data.slippageBps);
            collateralReceived = SWAP_ROUTER.exactInput(data.swapPath, amount, minOut);
        } else {
            uint256 minOut =
                _quoteMinOutSingle(asset, data.collateralAsset, data.swapPoolFee, amount, data.slippageBps);
            collateralReceived = SWAP_ROUTER.exactInputSingle(
                asset, data.collateralAsset, data.swapPoolFee, amount, minOut
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
        uint256
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
            uint256 minOut = _quoteMinOutPath(data.swapPath, collateralWithdrawn, data.slippageBps);
            SWAP_ROUTER.exactInput(data.swapPath, collateralWithdrawn, minOut);
        } else {
            uint256 minOut = _quoteMinOutSingle(
                data.collateralAsset, asset, data.swapPoolFee, collateralWithdrawn, data.slippageBps
            );
            SWAP_ROUTER.exactInputSingle(
                data.collateralAsset, asset, data.swapPoolFee, collateralWithdrawn, minOut
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

    function _validateCommonParams(
        address collateralAsset,
        address debtAsset,
        uint256 flashLoanAmount,
        uint16 slippageBps
    ) internal pure {
        require(collateralAsset != address(0) && debtAsset != address(0), "LeverageManager: zero address");
        require(collateralAsset != debtAsset, "LeverageManager: identical assets");
        require(flashLoanAmount > 0, "LeverageManager: invalid flash amount");
        require(slippageBps <= 10_000, "LeverageManager: invalid slippage");
    }

    function _quoteMinOutPath(bytes memory path, uint256 amountIn, uint16 slippageBps)
        internal
        returns (uint256 minOut)
    {
        uint256 quotedOut = QUOTER.quoteExactInput(path, amountIn);
        minOut = (quotedOut * (10_000 - slippageBps)) / 10_000;
    }

    function _quoteMinOutSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint16 slippageBps
    ) internal returns (uint256 minOut) {
        uint256 quotedOut = QUOTER.quoteExactInputSingle(tokenIn, tokenOut, fee, amountIn, 0);
        minOut = (quotedOut * (10_000 - slippageBps)) / 10_000;
    }

    function _validatePath(bytes memory path, address expectedTokenIn, address expectedTokenOut)
        internal
        pure
    {
        require(path.length >= 43 && (path.length - 20) % 23 == 0, "LeverageManager: invalid path");

        address tokenIn;
        address tokenOut;
        uint256 len = path.length;
        assembly {
            tokenIn := shr(96, mload(add(path, 32)))
            tokenOut := shr(96, mload(add(add(path, 32), sub(len, 20))))
        }

        require(tokenIn == expectedTokenIn, "LeverageManager: path tokenIn mismatch");
        require(tokenOut == expectedTokenOut, "LeverageManager: path tokenOut mismatch");
    }
}
