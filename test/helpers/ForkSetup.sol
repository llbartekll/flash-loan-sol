// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IPoolAddressesProvider} from "@aave/v3-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@aave/v3-core/contracts/interfaces/IPool.sol";
import {ICreditDelegationToken} from "@aave/v3-core/contracts/interfaces/ICreditDelegationToken.sol";
import {DataTypes} from "@aave/v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LeverageManager} from "../../src/LeverageManager.sol";

abstract contract ForkSetup is Test {
    // ── Optimism mainnet addresses ──
    IPoolAddressesProvider constant ADDRESSES_PROVIDER =
        IPoolAddressesProvider(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb);
    ISwapRouter constant SWAP_ROUTER =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IQuoter constant QUOTER = IQuoter(0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6);

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // USDC native on OP
    address constant WSTETH = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;

    IPool pool;
    LeverageManager leverageManager;

    address user = makeAddr("user");

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("OPTIMISM_RPC_URL"));

        pool = IPool(ADDRESSES_PROVIDER.getPool());
        leverageManager = new LeverageManager(ADDRESSES_PROVIDER, SWAP_ROUTER, QUOTER);
    }

    function _getAToken(address asset) internal view returns (address) {
        DataTypes.ReserveData memory data = pool.getReserveData(asset);
        return data.aTokenAddress;
    }

    function _getVariableDebtToken(address asset) internal view returns (address) {
        DataTypes.ReserveData memory data = pool.getReserveData(asset);
        return data.variableDebtTokenAddress;
    }

    function _dealToken(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
    }

    function _setupLeveragedPosition(
        address collateral,
        uint256 collateralAmount,
        address debt,
        uint256 debtAmount
    ) internal {
        _dealToken(collateral, user, collateralAmount);

        vm.startPrank(user);
        IERC20(collateral).approve(address(pool), collateralAmount);
        pool.supply(collateral, collateralAmount, user, 0);
        pool.borrow(debt, debtAmount, 2, 0, user);
        vm.stopPrank();
    }
}
