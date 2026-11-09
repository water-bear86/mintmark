// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import {ElysiumPreflight} from "./ElysiumPreflight.sol";
import "../launchpad/MintMarkLaunchpad.sol";
import "../launchpad/V2Migrator.sol";
import "../PluginRegistry.sol";
import "../plugins/launch/SplitPlugin.sol";
import "../plugins/launch/BuybackBurnPlugin.sol";
import "../plugins/launch/HolderDistributionPlugin.sol";
import "../plugins/launch/ComboPlugin.sol";

/// @notice Deploy the existing MintMark stack on Kinetiq Elysium using native HYPE.
/// Required configuration is documented in docs/ELYSIUM-MIGRATION.md.
/// Start with a simulation (no --broadcast). No chain, DEX or fee defaults are guessed.
contract DeployMintMark is Script {
    function run() external {
        address router = vm.envAddress("V2_ROUTER");
        bytes32 pairCodeHash = vm.envBytes32("V2_PAIR_CODE_HASH");
        address feeTo = vm.envAddress("FEE_TO");
        address feeToSetter = vm.envAddress("FEE_TO_SETTER");
        uint256 launchFee = vm.envUint("LAUNCH_FEE_WEI");
        uint256 listingFee = vm.envUint("LISTING_FEE_WEI");

        ElysiumPreflight.validate(vm.envUint("ELYSIUM_CHAIN_ID"), router, vm.envAddress("ELYSIUM_WHYPE"), pairCodeHash);
        require(feeTo != address(0) && feeToSetter != address(0), "fee recipients required");
        require(launchFee <= 0.01 ether && listingFee <= 0.05 ether, "fee cap exceeded");
        // Existing ABI names containing ETH remain for compatibility; native value is HYPE.
        vm.startBroadcast();
        V2Migrator migrator = new V2Migrator(router, pairCodeHash);
        MintMarkLaunchpad pad = new MintMarkLaunchpad(address(migrator), feeTo, feeToSetter, launchFee);

        SplitPlugin split = new SplitPlugin(address(pad));
        BuybackBurnPlugin buyback = new BuybackBurnPlugin(address(pad));
        HolderDistributionPlugin holders = new HolderDistributionPlugin(address(pad));
        ComboPlugin combo = new ComboPlugin(address(pad));

        PluginRegistry registry = new PluginRegistry(feeToSetter, listingFee);
        vm.stopBroadcast();

        console.log("V2Migrator        ", address(migrator));
        console.log("MintMarkLaunchpad ", address(pad));
        console.log("SplitPlugin       ", address(split));
        console.log("BuybackBurnPlugin ", address(buyback));
        console.log("HolderDistribution", address(holders));
        console.log("ComboPlugin       ", address(combo));
        console.log("PluginRegistry    ", address(registry));
        console.log("NOTE: list + verify the reference plugins from the curator account next (registry.list/setVerified).");
    }
}
