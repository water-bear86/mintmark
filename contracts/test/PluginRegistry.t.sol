// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../PluginRegistry.sol";

contract RejectingCurator {
    // no receive: collectFees to this curator reverts
}

contract PluginRegistryTest is Test {
    PluginRegistry reg;
    address curator = makeAddr("curator");
    address author = makeAddr("author");
    address other = makeAddr("other");
    address pluginA = makeAddr("pluginA");
    address pluginB = makeAddr("pluginB");

    function setUp() public {
        reg = new PluginRegistry(curator, 0.005 ether);
        vm.deal(author, 10 ether);
        vm.deal(other, 10 ether);
    }

    function test_constructor_guards() public {
        vm.expectRevert(PluginRegistry.ZeroAddress.selector);
        new PluginRegistry(address(0), 0);
        vm.expectRevert(PluginRegistry.FeeTooHigh.selector);
        new PluginRegistry(curator, 0.05 ether + 1);
    }

    function test_list_oncePerPluginAgainstTheExactFee() public {
        vm.prank(author);
        reg.list{value: 0.005 ether}(pluginA, "Split", "ipfs://split", 100);
        PluginRegistry.Listing memory l = reg.listingOf(pluginA);
        assertEq(l.plugin, pluginA);
        assertEq(l.author, author);
        assertEq(l.name, "Split");
        assertEq(l.metadataURI, "ipfs://split");
        assertEq(l.authorFeeBps, 100);
        assertFalse(l.verified);
        assertEq(reg.pluginsLength(), 1);
        assertEq(reg.pluginAt(0), pluginA);
        assertTrue(reg.isListed(pluginA));
        assertEq(reg.pendingFees(), 0.005 ether);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PluginRegistry.AlreadyListed.selector, pluginA));
        reg.list{value: 0.005 ether}(pluginA, "Again", "", 0);

        vm.prank(author);
        vm.expectRevert(abi.encodeWithSelector(PluginRegistry.WrongValue.selector, 0.005 ether, 0.004 ether));
        reg.list{value: 0.004 ether}(pluginB, "B", "", 0);

        vm.prank(author);
        vm.expectRevert(PluginRegistry.InvalidName.selector);
        reg.list{value: 0.005 ether}(pluginB, "", "", 0);
    }

    function test_update_authorOnlyAndClearsVerified() public {
        vm.prank(author);
        reg.list{value: 0.005 ether}(pluginA, "Split", "ipfs://v1", 100);
        vm.prank(curator);
        reg.setVerified(pluginA, true);
        assertTrue(reg.listingOf(pluginA).verified);

        vm.prank(other);
        vm.expectRevert(PluginRegistry.Forbidden.selector);
        reg.update(pluginA, "ipfs://evil", 0);

        vm.prank(author);
        reg.update(pluginA, "ipfs://v2", 250);
        PluginRegistry.Listing memory l = reg.listingOf(pluginA);
        assertEq(l.metadataURI, "ipfs://v2");
        assertEq(l.authorFeeBps, 250);
        assertFalse(l.verified, "an author edit clears the badge");
    }

    function test_verify_curatorOnly_andRenounceFreezesBadges() public {
        vm.prank(author);
        reg.list{value: 0.005 ether}(pluginA, "Split", "", 0);
        vm.prank(other);
        vm.expectRevert(PluginRegistry.Forbidden.selector);
        reg.setVerified(pluginA, true);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(PluginRegistry.NotListed.selector, pluginB));
        reg.setVerified(pluginB, true);
        vm.prank(curator);
        reg.setVerified(pluginA, true);

        reg.collectFees(); // renouncing requires the pending listing fees collected first
        vm.prank(curator);
        reg.setCurator(address(0));
        vm.prank(curator);
        vm.expectRevert(PluginRegistry.Forbidden.selector);
        reg.setVerified(pluginA, false);
        assertTrue(reg.listingOf(pluginA).verified, "badges freeze on renounce");
    }

    function test_fees_accrueAndCollectToTheCurator() public {
        vm.prank(author);
        reg.list{value: 0.005 ether}(pluginA, "A", "", 0);
        vm.prank(other);
        reg.list{value: 0.005 ether}(pluginB, "B", "", 0);
        assertEq(reg.pendingFees(), 0.01 ether);
        assertEq(reg.collectFees(), 0.01 ether);
        assertEq(curator.balance, 0.01 ether);
        assertEq(reg.collectFees(), 0, "nothing left");

        vm.prank(curator);
        reg.setListingFee(0);
        vm.prank(author);
        reg.list(makeAddr("pluginC"), "C", "", 0);
        vm.prank(curator);
        vm.expectRevert(PluginRegistry.FeeTooHigh.selector);
        reg.setListingFee(0.05 ether + 1);
    }

    function test_page_clampsAndSlices() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(author);
            reg.list{value: 0.005 ether}(address(uint160(0x1000 + i)), "P", "", 0);
        }
        PluginRegistry.Listing[] memory pageOne = reg.page(1, 2);
        assertEq(pageOne.length, 2);
        assertEq(pageOne[0].plugin, address(uint160(0x1001)));
        assertEq(reg.page(4, 100).length, 1);
        assertEq(reg.page(5, 1).length, 0);
    }

    function test_listingOf_unknownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PluginRegistry.NotListed.selector, pluginA));
        reg.listingOf(pluginA);
        assertFalse(reg.isListed(pluginA));
    }
}
