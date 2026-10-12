// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "The Comb");
        assertEq(token.symbol(), "COMB");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_transfer() public {
        assertTrue(token.transfer(alice, 100e18));
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(address(this)), 1e27 - 100e18);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InvalidAddress.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        token.approve(alice, 50);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 30);
        assertEq(token.balanceOf(bob), 30);
        assertEq(token.allowance(address(this), alice), 20);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, alice, 20, 21));
        token.transferFrom(address(this), bob, 21);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 30);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function test_noMintSelector() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(address(this)), 1e27);
    }
}
