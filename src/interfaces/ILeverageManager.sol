// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILeverageManager {
    enum Operation {
        LEVERAGE_UP,
        DELEVERAGE
    }

    struct LeverageParams {
        address collateralAsset;
        address debtAsset;
        uint256 flashLoanAmount;
        uint24 swapPoolFee;
        uint16 slippageBps;
        bytes swapPath;
    }

    struct DeleverageParams {
        address collateralAsset;
        address debtAsset;
        uint256 flashLoanAmount;
        uint256 collateralToWithdraw;
        uint24 swapPoolFee;
        uint16 slippageBps;
        bytes swapPath;
    }

    event LeveragedUp(
        address indexed user,
        address indexed collateralAsset,
        address indexed debtAsset,
        uint256 flashLoanAmount,
        uint256 collateralSupplied
    );

    event Deleveraged(
        address indexed user,
        address indexed collateralAsset,
        address indexed debtAsset,
        uint256 debtRepaid,
        uint256 collateralWithdrawn
    );

    function leverageUp(LeverageParams calldata params) external;

    function deleverage(DeleverageParams calldata params) external;
}
