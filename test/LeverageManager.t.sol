// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkSetup} from "./helpers/ForkSetup.sol";
import {ILeverageManager} from "../src/interfaces/ILeverageManager.sol";
import {ICreditDelegationToken} from "@aave/v3-core/contracts/interfaces/ICreditDelegationToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LeverageManagerTest is ForkSetup {
    uint24 constant FEE_500 = 500;
    uint24 constant FEE_3000 = 3000;
    uint16 constant SLIPPAGE_100_BPS = 100;

    // ──────────────────────────────────────────────
    // Leverage Up Tests
    // ──────────────────────────────────────────────

    function test_leverageUp_wstETH_USDC() public {
        // Setup: user supplies wstETH as collateral
        uint256 collateralAmount = 2 ether;
        _dealToken(WSTETH, user, collateralAmount);

        vm.startPrank(user);
        IERC20(WSTETH).approve(address(pool), collateralAmount);
        pool.supply(WSTETH, collateralAmount, user, 0);

        // Grant credit delegation to the leverage manager for USDC variable debt
        address variableDebtUSDC = _getVariableDebtToken(USDC);
        ICreditDelegationToken(variableDebtUSDC).approveDelegation(
            address(leverageManager), type(uint256).max
        );

        // Leverage up: flash borrow USDC, swap to wstETH, supply, borrow USDC to repay
        // Multi-hop path: USDC -> WETH -> wstETH
        bytes memory path = abi.encodePacked(USDC, FEE_500, WETH, FEE_100(), WSTETH);

        ILeverageManager.LeverageParams memory params = ILeverageManager.LeverageParams({
            collateralAsset: WSTETH,
            debtAsset: USDC,
            flashLoanAmount: 500e6, // 500 USDC
            swapPoolFee: 0, // unused when swapPath is set
            slippageBps: SLIPPAGE_100_BPS,
            swapPath: path
        });

        leverageManager.leverageUp(params);
        vm.stopPrank();

        // Verify: user should have more wstETH collateral and USDC debt
        address aWSTETH = _getAToken(WSTETH);
        uint256 aTokenBalance = IERC20(aWSTETH).balanceOf(user);
        assertGt(aTokenBalance, collateralAmount, "Should have more collateral after leverage up");

        uint256 debtBalance = IERC20(variableDebtUSDC).balanceOf(user);
        assertGt(debtBalance, 0, "Should have USDC debt after leverage up");
    }

    function test_leverageUp_WETH_USDC() public {
        // Setup: user supplies WETH as collateral
        uint256 collateralAmount = 2 ether;
        _dealToken(WETH, user, collateralAmount);

        vm.startPrank(user);
        IERC20(WETH).approve(address(pool), collateralAmount);
        pool.supply(WETH, collateralAmount, user, 0);

        // Grant credit delegation
        address variableDebtUSDC = _getVariableDebtToken(USDC);
        ICreditDelegationToken(variableDebtUSDC).approveDelegation(
            address(leverageManager), type(uint256).max
        );

        // Single-hop: USDC → WETH
        ILeverageManager.LeverageParams memory params = ILeverageManager.LeverageParams({
            collateralAsset: WETH,
            debtAsset: USDC,
            flashLoanAmount: 500e6,
            swapPoolFee: FEE_500,
            slippageBps: SLIPPAGE_100_BPS,
            swapPath: ""
        });

        leverageManager.leverageUp(params);
        vm.stopPrank();

        address aWETH = _getAToken(WETH);
        assertGt(IERC20(aWETH).balanceOf(user), collateralAmount);
        assertGt(IERC20(variableDebtUSDC).balanceOf(user), 0);
    }

    function test_leverageUp_reverts_noCreditDelegation() public {
        uint256 collateralAmount = 2 ether;
        _dealToken(WETH, user, collateralAmount);

        vm.startPrank(user);
        IERC20(WETH).approve(address(pool), collateralAmount);
        pool.supply(WETH, collateralAmount, user, 0);

        // No credit delegation granted
        ILeverageManager.LeverageParams memory params = ILeverageManager.LeverageParams({
            collateralAsset: WETH,
            debtAsset: USDC,
            flashLoanAmount: 500e6,
            swapPoolFee: FEE_500,
            slippageBps: SLIPPAGE_100_BPS,
            swapPath: ""
        });

        vm.expectRevert();
        leverageManager.leverageUp(params);
        vm.stopPrank();
    }

    function test_leverageUp_reverts_insufficientCollateral() public {
        // Tiny collateral, huge flash loan → health factor will drop below 1
        uint256 collateralAmount = 0.01 ether;
        _dealToken(WETH, user, collateralAmount);

        vm.startPrank(user);
        IERC20(WETH).approve(address(pool), collateralAmount);
        pool.supply(WETH, collateralAmount, user, 0);

        address variableDebtUSDC = _getVariableDebtToken(USDC);
        ICreditDelegationToken(variableDebtUSDC).approveDelegation(
            address(leverageManager), type(uint256).max
        );

        ILeverageManager.LeverageParams memory params = ILeverageManager.LeverageParams({
            collateralAsset: WETH,
            debtAsset: USDC,
            flashLoanAmount: 50_000e6, // Way too much for 0.01 ETH collateral
            swapPoolFee: FEE_500,
            slippageBps: SLIPPAGE_100_BPS,
            swapPath: ""
        });

        vm.expectRevert();
        leverageManager.leverageUp(params);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // Deleverage Tests
    // ──────────────────────────────────────────────

    function test_deleverage_partial() public {
        // Setup a leveraged position: 2 WETH collateral, 500 USDC debt
        _setupLeveragedPosition(WETH, 2 ether, USDC, 500e6);

        address aWETH = _getAToken(WETH);
        address variableDebtUSDC = _getVariableDebtToken(USDC);
        uint256 debtBefore = IERC20(variableDebtUSDC).balanceOf(user);
        uint256 aTokenBefore = IERC20(aWETH).balanceOf(user);

        vm.startPrank(user);
        // Approve aToken transfer for deleverage
        IERC20(aWETH).approve(address(leverageManager), 0.5 ether);

        ILeverageManager.DeleverageParams memory params = ILeverageManager.DeleverageParams({
            collateralAsset: WETH,
            debtAsset: USDC,
            flashLoanAmount: 250e6, // Repay 250 USDC of debt
            collateralToWithdraw: 0.5 ether,
            swapPoolFee: FEE_500,
            slippageBps: SLIPPAGE_100_BPS,
            swapPath: ""
        });

        leverageManager.deleverage(params);
        vm.stopPrank();

        uint256 debtAfter = IERC20(variableDebtUSDC).balanceOf(user);
        uint256 aTokenAfter = IERC20(aWETH).balanceOf(user);

        assertLt(debtAfter, debtBefore, "Debt should decrease");
        assertLt(aTokenAfter, aTokenBefore, "Collateral should decrease");
    }

    function test_deleverage_full() public {
        _setupLeveragedPosition(WETH, 2 ether, USDC, 500e6);

        address aWETH = _getAToken(WETH);
        address variableDebtUSDC = _getVariableDebtToken(USDC);
        uint256 fullDebt = IERC20(variableDebtUSDC).balanceOf(user);
        uint256 fullAToken = IERC20(aWETH).balanceOf(user);

        vm.startPrank(user);
        IERC20(aWETH).approve(address(leverageManager), fullAToken);

        ILeverageManager.DeleverageParams memory params = ILeverageManager.DeleverageParams({
            collateralAsset: WETH,
            debtAsset: USDC,
            flashLoanAmount: fullDebt + 1e6, // Slightly more to cover any accrued interest
            collateralToWithdraw: fullAToken,
            swapPoolFee: FEE_500,
            slippageBps: SLIPPAGE_100_BPS,
            swapPath: ""
        });

        leverageManager.deleverage(params);
        vm.stopPrank();

        uint256 debtAfter = IERC20(variableDebtUSDC).balanceOf(user);
        assertEq(debtAfter, 0, "All debt should be repaid");
    }

    function test_deleverage_reverts_noATokenApproval() public {
        _setupLeveragedPosition(WETH, 2 ether, USDC, 500e6);

        vm.startPrank(user);
        // No aToken approval

        ILeverageManager.DeleverageParams memory params = ILeverageManager.DeleverageParams({
            collateralAsset: WETH,
            debtAsset: USDC,
            flashLoanAmount: 250e6,
            collateralToWithdraw: 0.5 ether,
            swapPoolFee: FEE_500,
            slippageBps: SLIPPAGE_100_BPS,
            swapPath: ""
        });

        vm.expectRevert();
        leverageManager.deleverage(params);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // Security Tests
    // ──────────────────────────────────────────────

    function test_executeOperation_reverts_unauthorizedCaller() public {
        bytes memory fakeParams = abi.encode(
            ILeverageManager.Operation.LEVERAGE_UP,
            user,
            WETH,
            USDC,
            uint256(0),
            uint24(FEE_500),
            uint16(100),
            bytes("")
        );

        vm.prank(user); // Not the Pool
        vm.expectRevert("LeverageManager: caller must be Pool");
        leverageManager.executeOperation(USDC, 1000e6, 1e6, address(leverageManager), fakeParams);
    }

    function test_executeOperation_reverts_unauthorizedInitiator() public {
        bytes memory fakeParams = abi.encode(
            ILeverageManager.Operation.LEVERAGE_UP,
            user,
            WETH,
            USDC,
            uint256(0),
            uint24(FEE_500),
            uint16(100),
            bytes("")
        );

        vm.prank(address(pool)); // Correct caller
        vm.expectRevert("LeverageManager: initiator must be this contract");
        leverageManager.executeOperation(USDC, 1000e6, 1e6, user, fakeParams); // Wrong initiator
    }

    function test_noFundsLeftInContract() public {
        // Setup and do a leverage up
        uint256 collateralAmount = 2 ether;
        _dealToken(WETH, user, collateralAmount);

        vm.startPrank(user);
        IERC20(WETH).approve(address(pool), collateralAmount);
        pool.supply(WETH, collateralAmount, user, 0);

        address variableDebtUSDC = _getVariableDebtToken(USDC);
        ICreditDelegationToken(variableDebtUSDC).approveDelegation(
            address(leverageManager), type(uint256).max
        );

        ILeverageManager.LeverageParams memory params = ILeverageManager.LeverageParams({
            collateralAsset: WETH,
            debtAsset: USDC,
            flashLoanAmount: 500e6,
            swapPoolFee: FEE_500,
            slippageBps: SLIPPAGE_100_BPS,
            swapPath: ""
        });

        leverageManager.leverageUp(params);
        vm.stopPrank();

        // Verify no funds left in contract
        assertEq(IERC20(WETH).balanceOf(address(leverageManager)), 0, "WETH stuck in contract");
        assertEq(IERC20(USDC).balanceOf(address(leverageManager)), 0, "USDC stuck in contract");
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function FEE_100() internal pure returns (uint24) {
        return 100;
    }
}
