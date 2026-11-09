// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {ElysiumClock} from "../libraries/ElysiumClock.sol";
contract ElysiumClockHarness {
    uint256 public nextBlock;
    function current() external view returns (uint256) { return ElysiumClock.blockNumber(); }
    function run() external { uint256 n = ElysiumClock.blockNumber(); require(n >= nextBlock,"cooldown"); nextBlock = n + 1; }
}
contract ElysiumClockTest is Test {
    ElysiumClockHarness h = new ElysiumClockHarness();
    function setLocalBlock(uint256 n) internal { vm.mockCall(address(0x64),abi.encodeWithSignature("arbBlockNumber()"),abi.encode(n)); }
    function test_parentBlockDoesNotThrottleChildBlocks() public {
        vm.chainId(99901); vm.roll(100); setLocalBlock(1000);
        h.run(); assertEq(h.nextBlock(),1001);
        vm.expectRevert(bytes("cooldown")); h.run();
        setLocalBlock(1001); h.run(); assertEq(h.nextBlock(),1002); assertEq(block.number,100);
    }
    function test_testnetUsesArbSys() public { vm.chainId(99801); vm.roll(10); setLocalBlock(500); assertEq(h.current(),500); }
    function test_oldChainKeepsNativeClock() public { vm.chainId(59144); vm.roll(42); assertEq(h.current(),42); }
    function test_missingArbSysFailsClosed() public { vm.chainId(99901); vm.expectRevert(ElysiumClock.ArbSysUnavailable.selector); h.current(); }
    function test_malformedArbSysFailsClosed() public { vm.chainId(99901); vm.mockCall(address(0x64),abi.encodeWithSignature("arbBlockNumber()"),hex"01"); vm.expectRevert(ElysiumClock.ArbSysUnavailable.selector); h.current(); }
}
