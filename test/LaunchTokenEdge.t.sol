// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @dev Boundary and failure-path cases for the launch token beyond the base suite: zero and full amounts,
/// self-transfers, exact and infinite allowances, reverted calls leaving allowances untouched, events,
/// the deployer holding the whole supply, and the shapes the launch floor refuses.
/// forge-config: default.fuzz.runs = 1000
contract LaunchTokenEdgeTest is Test {
    LaunchToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant SUPPLY = 1_000_000_000e18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new LaunchToken();
    }

    // --- supply ---

    function test_constructorMintsExactlyOnceToDeployer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        LaunchToken t = new LaunchToken();
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.TOTAL_SUPPLY(), SUPPLY);
        assertEq(t.balanceOf(alice), SUPPLY);
        assertEq(t.balanceOf(address(this)), 0);
        assertEq(t.balanceOf(address(0)), 0);
    }

    function test_supplyIsExactlyOneBillionWholeTokens() public view {
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.totalSupply() / 10 ** uint256(token.decimals()), 1_000_000_000);
    }

    // --- transfer edges ---

    function test_transferZeroAmountSucceedsAndEmits() public {
        vm.expectEmit(address(token));
        emit Transfer(address(this), alice, 0);
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferZeroFromEmptyAccountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFullBalance() public {
        vm.expectEmit(address(token));
        emit Transfer(address(this), alice, SUPPLY);
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, address(this), 0, 1));
        token.transfer(alice, 1);
    }

    function test_transferOneWeiOverBalanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_selfTransferIsANoOp(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.expectEmit(address(token));
        emit Transfer(address(this), address(this), amount);
        token.transfer(address(this), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferOverBalanceReverts() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, alice, 10, 11));
        token.transfer(alice, 11);
        assertEq(token.balanceOf(alice), 10);
    }

    function testFuzz_transferOverBalanceRevertsWithExactArgs(uint256 held, uint256 extra) public {
        held = bound(held, 0, SUPPLY);
        extra = bound(extra, 1, type(uint256).max - held);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, alice, held, held + extra));
        token.transfer(bob, held + extra);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
    }

    function testFuzz_transferChainConservesSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(address(this), c);
        assertEq(token.balanceOf(address(this)), SUPPLY - a + c);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b - c);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
    }

    // --- approvals ---

    function test_approveEmitsAndOverwrites() public {
        vm.expectEmit(address(token));
        emit Approval(address(this), alice, 5);
        assertTrue(token.approve(alice, 5));
        assertEq(token.allowance(address(this), alice), 5);
        // overwrite, not accumulate
        token.approve(alice, 3);
        assertEq(token.allowance(address(this), alice), 3);
        token.approve(alice, 0);
        assertEq(token.allowance(address(this), alice), 0);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InvalidAddress.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_approveDoesNotRequireBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(bob, SUPPLY * 10));
        assertEq(token.allowance(alice, bob), SUPPLY * 10);
        // but spending it still needs the balance
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_approveToSelfThenTransferFromSelf() public {
        token.approve(address(this), 10);
        token.transferFrom(address(this), alice, 4);
        assertEq(token.allowance(address(this), address(this)), 6);
        assertEq(token.balanceOf(alice), 4);
    }

    // --- transferFrom edges ---

    function test_transferFromWithoutApprovalReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(this), bob, 1);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromZeroAmountWithoutApprovalSucceeds() public {
        vm.expectEmit(address(token));
        emit Transfer(address(this), bob, 0);
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 0));
        assertEq(token.allowance(address(this), alice), 0);
    }

    function test_transferFromExactAllowanceThenNothingLeft() public {
        token.approve(alice, 50);
        vm.expectEmit(address(token));
        emit Transfer(address(this), bob, 50);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 50);
        assertEq(token.allowance(address(this), alice), 0);
        assertEq(token.balanceOf(bob), 50);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(this), bob, 1);
    }

    function test_transferFromToZeroRevertsAndKeepsAllowance() public {
        token.approve(alice, 50);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InvalidAddress.selector, address(0)));
        token.transferFrom(address(this), address(0), 10);
        assertEq(token.allowance(address(this), alice), 50);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferFromOverBalanceRevertsAndKeepsAllowance() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, alice, 10, 11));
        token.transferFrom(alice, bob, 11);
        assertEq(token.allowance(alice, bob), 100, "a reverted transferFrom consumed allowance");
        assertEq(token.balanceOf(alice), 10);
    }

    function test_infiniteAllowanceStillNeedsBalance() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, alice, 10, 11));
        token.transferFrom(alice, bob, 11);
        vm.prank(bob);
        token.transferFrom(alice, bob, 10);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(bob), 10);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_maxMinusOneAllowanceIsFinite() public {
        token.approve(alice, type(uint256).max - 1);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), alice), type(uint256).max - 2);
    }

    function test_allowanceIsPerSpender() public {
        token.approve(alice, 10);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), alice), 10);
    }

    function testFuzz_transferFromDecrementsExactly(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, SUPPLY);
        spent = bound(spent, 0, allowed);
        token.approve(alice, allowed);
        vm.prank(alice);
        token.transferFrom(address(this), bob, spent);
        assertEq(token.allowance(address(this), alice), allowed - spent);
        assertEq(token.balanceOf(bob), spent);
        assertEq(token.balanceOf(address(this)), SUPPLY - spent);
    }

    function testFuzz_transferFromOverAllowanceReverts(uint256 allowed, uint256 extra) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        extra = bound(extra, 1, SUPPLY - allowed);
        token.approve(alice, allowed);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, alice, allowed, allowed + extra)
        );
        token.transferFrom(address(this), bob, allowed + extra);
        assertEq(token.allowance(address(this), alice), allowed);
        assertEq(token.balanceOf(bob), 0);
    }

    // --- surface that must not exist ---

    function test_noMintBurnOrAdminFromAnyone() public {
        string[12] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "setOwner(address)",
            "pause()",
            "unpause()",
            "upgradeTo(address)",
            "initialize(address)",
            "setFee(uint256)"
        ];
        address[2] memory callers = [address(this), alice];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < sigs.length; ++i) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], alice, uint256(1)));
                assertFalse(ok, sigs[i]);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_rejectsEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 wei}("");
        assertFalse(ok);
        vm.prank(alice);
        (ok,) = address(token).call{value: 1 wei}(abi.encodeCall(LaunchToken.transfer, (bob, 0)));
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
