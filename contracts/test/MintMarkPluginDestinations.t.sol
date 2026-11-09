// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./launchpad/MintMarkBase.sol";
import {ILaunchFeePlugin} from "../interfaces/plugins/ILaunchFeePlugin.sol";
import {SplitPlugin} from "../plugins/launch/SplitPlugin.sol";
import {ComboPlugin} from "../plugins/launch/ComboPlugin.sol";

/// @notice createToken refuses fee destinations that could never pass fees on, and pluginData that no plugin would
///         read. A new token's address and its DEX pool's are predictable (the launchpad's next CREATE and the
///         migrator's pairFor), so they are predicted here the way a confused builder or an attacker would.
contract LaunchpadPluginDestinationTest is MintMarkBase {
    function _predictToken() internal view returns (address) {
        return vm.computeCreateAddress(address(pad), vm.getNonce(address(pad)));
    }

    function _predictPool() internal view returns (address) {
        return migrator.poolFor(_predictToken());
    }

    /// @dev A launch paying `plugin` reverts InvalidPlugin and leaves nothing behind.
    function _expectInvalid(address plugin) internal {
        uint256 tokens = pad.tokensLength();
        vm.prank(alice);
        vm.expectRevert(IMintMarkLaunchpad.InvalidPlugin.selector);
        pad.createToken{value: (10e6 * 2e8)}("Bad", "BAD", "", 100, plugin, "", 0, type(uint256).max);
        assertEq(pad.tokensLength(), tokens);
    }

    // ─── InvalidPlugin ────────────────────────────────────────────────────────

    function test_rejectsTheMigrator() public {
        _expectInvalid(address(migrator));
    }

    function test_stillRejectsZeroAndTheLaunchpad() public {
        _expectInvalid(address(0));
        _expectInvalid(address(pad));
    }

    /// @dev The new token itself: the fees would sit in the token's contract, uncredited.
    function test_rejectsTheNewTokenItself() public {
        address predicted = _predictToken();
        _expectInvalid(predicted);
        assertEq(_create(100, creatorWallet), predicted, "the prediction was right");
    }

    /// @dev Its own DEX pool: a V2 pair cannot receive ETH, so the fees could never be collected.
    function test_rejectsItsOwnPool() public {
        address predicted = _predictPool();
        _expectInvalid(predicted);
        address token = _create(100, creatorWallet);
        assertEq(pad.poolOf(token), predicted, "the prediction was right");
    }

    function test_rejectsAnyOtherLaunchToken() public {
        address live = _create(100, creatorWallet);
        address graduated = _create(0, alice);
        _graduate(graduated);
        _expectInvalid(live);
        _expectInvalid(graduated);
    }

    /// @dev The dead address stays allowed: burning the creator fees is a choice.
    function test_deadAddressIsAllowed() public {
        address token = _create(500, DEAD);
        vm.prank(carol);
        pad.buy{value: (1_000e6 * 2e8)}(token, 0, carol, type(uint256).max);
        uint256 owed = pad.pendingCreatorFees(token);
        uint256 before = DEAD.balance;
        assertEq(pad.collectCreatorFees(token), owed);
        assertEq(DEAD.balance - before, owed);
        _assertSolvent();
    }

    // ─── DataForNonPlugin ─────────────────────────────────────────────────────

    /// @dev A mistyped Split address: the creator's 50/50 configuration would be dropped and every fee would go to the
    ///      typo. The launch reverts instead; the right address launches, configured.
    function test_pluginDataForANonPluginReverts_mistypedSplit() public {
        SplitPlugin split = new SplitPlugin(address(pad));
        bytes memory config = abi.encode(_two(alice, bob), _twoShares(1, 1));
        address typo = address(uint160(address(split)) ^ 1);

        vm.prank(alice);
        vm.expectRevert(IMintMarkLaunchpad.DataForNonPlugin.selector);
        pad.createToken("Typo", "TYPO", "", 300, typo, config, 0, type(uint256).max);

        vm.prank(alice);
        address token = pad.createToken("Right", "RIGHT", "", 300, address(split), config, 0, type(uint256).max);
        assertTrue(split.isConfigured(token));
    }

    /// @dev Contracts without the interface, and the dead address, take empty data only.
    function test_pluginDataForANonPluginReverts_contractsAndDead() public {
        address[3] memory plain = [address(new HooklessRecorder()), address(new GasGuzzlerPlugin()), DEAD];
        for (uint256 i; i < plain.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(IMintMarkLaunchpad.DataForNonPlugin.selector);
            pad.createToken("Data", "DATA", "", 100, plain[i], hex"00", 0, type(uint256).max);
            vm.prank(alice);
            pad.createToken("Data", "DATA", "", 100, plain[i], "", 0, type(uint256).max);
        }
    }

    // ─── The plugins' own check, on the real launchpad ────────────────────────

    /// @dev A Split payee or Combo target that is the launchpad, the migrator or a launch token is refused,
    ///      so the launch reverts.
    function test_splitAndComboRefuseStrandingRecipients() public {
        SplitPlugin split = new SplitPlugin(address(pad));
        ComboPlugin combo = new ComboPlugin(address(pad));
        address other = _create(100, creatorWallet);
        address[3] memory bad = [address(pad), address(migrator), other];

        for (uint256 i; i < bad.length; ++i) {
            bytes memory splitData = abi.encode(_two(alice, bad[i]), _twoShares(1, 1));
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(ILaunchFeePlugin.InvalidRecipient.selector, bad[i]));
            pad.createToken("S", "S", "", 100, address(split), splitData, 0, type(uint256).max);

            uint16[] memory bps = new uint16[](2);
            (bps[0], bps[1]) = (5000, 5000);
            bytes memory comboData = abi.encode(_two(alice, bad[i]), bps, new bytes[](2));
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(ILaunchFeePlugin.InvalidRecipient.selector, bad[i]));
            pad.createToken("C", "C", "", 100, address(combo), comboData, 0, type(uint256).max);
        }
        assertEq(pad.tokensLength(), 1);
    }

    function _two(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (a, b);
    }

    function _twoShares(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (a, b);
    }
}
