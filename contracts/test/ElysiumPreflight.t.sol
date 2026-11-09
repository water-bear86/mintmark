// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test} from "forge-std/Test.sol";
import {ElysiumPreflight} from "../script/ElysiumPreflight.sol";
contract ElysiumPreflightHarness {
    function validate(uint256 chain, address router, address wrapped, bytes32 hash) external view {
        ElysiumPreflight.validate(chain, router, wrapped, hash);
    }
}
contract ElysiumPreflightTest is Test {
    ElysiumPreflightHarness h = new ElysiumPreflightHarness();
    function test_rejectsLinea() public { vm.chainId(59144); vm.expectRevert(ElysiumPreflight.WrongChain.selector); h.validate(59144,address(1),address(2),bytes32(uint256(1))); }
    function test_rejectsOtherElysium() public { vm.chainId(1339); vm.expectRevert(ElysiumPreflight.WrongChain.selector); h.validate(1339,address(1),address(2),bytes32(uint256(1))); }
    function test_rejectsUnexpectedNetwork() public { vm.chainId(99801); vm.expectRevert(ElysiumPreflight.WrongChain.selector); h.validate(99901,address(1),address(2),bytes32(uint256(1))); }
    function test_rejectsUndeployedDex() public { vm.chainId(99901); vm.expectRevert(ElysiumPreflight.InvalidConfiguration.selector); h.validate(99901,address(1),address(2),bytes32(uint256(1))); }
    function test_rejectsWrongTestnetWrappedToken() public { vm.chainId(99801); vm.etch(address(10),hex"00"); vm.etch(address(20),hex"00"); vm.expectRevert(ElysiumPreflight.InvalidConfiguration.selector); h.validate(99801,address(10),address(20),bytes32(uint256(1))); }

    function validDex() internal returns (address router, address wrapped, bytes32 hash) {
        vm.chainId(99901);
        router = address(100); wrapped = address(200); hash = keccak256("pair creation code");
        address factory = address(300);
        address t0 = address(400); address t1 = address(500);
        address pair = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(t0,t1)), hash)))));
        vm.etch(router,hex"00"); vm.etch(wrapped,hex"00"); vm.etch(factory,hex"00"); vm.etch(pair,hex"00");
        vm.mockCall(router,abi.encodeWithSignature("WETH()"),abi.encode(wrapped));
        vm.mockCall(router,abi.encodeWithSignature("factory()"),abi.encode(factory));
        vm.mockCall(factory,abi.encodeWithSignature("allPairsLength()"),abi.encode(uint256(1)));
        vm.mockCall(factory,abi.encodeWithSignature("allPairs(uint256)",0),abi.encode(pair));
        vm.mockCall(factory,abi.encodeWithSignature("getPair(address,address)",t0,t1),abi.encode(pair));
        vm.mockCall(pair,abi.encodeWithSignature("token0()"),abi.encode(t0));
        vm.mockCall(pair,abi.encodeWithSignature("token1()"),abi.encode(t1));
    }
    function test_acceptsVerifiedDex() public {
        (address router,address wrapped,bytes32 hash) = validDex();
        h.validate(99901,router,wrapped,hash);
    }
    function test_rejectsEmptyFactory() public {
        (address router,address wrapped,bytes32 hash) = validDex();
        vm.mockCall(address(300),abi.encodeWithSignature("allPairsLength()"),abi.encode(uint256(0)));
        vm.expectRevert(ElysiumPreflight.InvalidDex.selector);
        h.validate(99901,router,wrapped,hash);
    }
    function test_rejectsRouterWrongWrapper() public {
        (address router,address wrapped,bytes32 hash) = validDex();
        vm.mockCall(router,abi.encodeWithSignature("WETH()"),abi.encode(address(999)));
        vm.expectRevert(ElysiumPreflight.InvalidDex.selector);
        h.validate(99901,router,wrapped,hash);
    }
    function test_rejectsBadPairHash() public {
        (address router,address wrapped,) = validDex();
        vm.expectRevert(ElysiumPreflight.InvalidDex.selector);
        h.validate(99901,router,wrapped,keccak256("wrong hash"));
    }
}
