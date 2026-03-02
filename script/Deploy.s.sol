// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IPoolAddressesProvider} from "@aave/v3-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import {LeverageManager} from "../src/LeverageManager.sol";

contract Deploy is Script {
    // Optimism mainnet addresses
    IPoolAddressesProvider constant ADDRESSES_PROVIDER =
        IPoolAddressesProvider(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb);
    ISwapRouter constant SWAP_ROUTER =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        LeverageManager manager = new LeverageManager(ADDRESSES_PROVIDER, SWAP_ROUTER);
        console.log("LeverageManager deployed at:", address(manager));

        vm.stopBroadcast();
    }
}
