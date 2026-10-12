// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CombWall} from "../src/CombWall.sol";

contract CombWallTest is Test {
    CombWall wall;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event Claimed(address indexed owner, uint16 indexed cellId, string message);
    event Carved(address indexed owner, uint16 indexed cellId, string message);
    event Released(address indexed owner, uint16 indexed cellId);

    function setUp() public {
        vm.warp(1_700_000_000);
        wall = new CombWall();
    }

    function _msg(uint256 len) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i; i < len; ++i) {
            b[i] = "a";
        }
        return string(b);
    }

    // --- claim ---

    function test_claim() public {
        vm.expectEmit(address(wall));
        emit Claimed(alice, 7, "hello hive");
        vm.prank(alice);
        wall.claim(7, "hello hive");
        assertEq(wall.ownerOf(7), alice);
        assertEq(wall.messageOf(7), "hello hive");
        assertEq(wall.cellOf(alice), 7);
        assertTrue(wall.hasCell(alice));
        assertEq(wall.claimedCount(), 1);
    }

    function test_unclaimedDefaults() public view {
        assertEq(wall.ownerOf(0), address(0));
        assertEq(wall.messageOf(0), "");
        assertEq(wall.cellOf(alice), wall.NO_CELL());
        assertFalse(wall.hasCell(alice));
        assertEq(wall.claimedCount(), 0);
        assertEq(wall.nextCarveAt(0), 0);
    }

    function test_claimCellZeroIsDistinguishableFromNone() public {
        vm.prank(alice);
        wall.claim(0, "zero");
        assertEq(wall.cellOf(alice), 0);
        assertTrue(wall.hasCell(alice));
    }

    function test_claimTakenCellReverts() public {
        vm.prank(alice);
        wall.claim(3, "mine");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CombWall.CellTaken.selector, uint16(3), alice));
        wall.claim(3, "no, mine");
    }

    function test_oneCellPerWallet() public {
        vm.startPrank(alice);
        wall.claim(3, "first");
        vm.expectRevert(abi.encodeWithSelector(CombWall.AlreadyHoldsCell.selector, alice, uint16(3)));
        wall.claim(4, "second");
        vm.stopPrank();
        assertEq(wall.ownerOf(4), address(0));
        assertEq(wall.claimedCount(), 1);
    }

    function test_claimOutOfRangeReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.InvalidCell.selector, uint16(1024)));
        wall.claim(1024, "edge");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.InvalidCell.selector, type(uint16).max));
        wall.claim(type(uint16).max, "edge");
    }

    function test_claimLastCell() public {
        vm.prank(alice);
        wall.claim(1023, "last");
        assertEq(wall.ownerOf(1023), alice);
    }

    function test_messageLengthLimits() public {
        vm.prank(alice);
        vm.expectRevert(CombWall.EmptyMessage.selector);
        wall.claim(1, "");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.MessageTooLong.selector, 65, 64));
        wall.claim(1, _msg(65));

        vm.prank(alice);
        wall.claim(1, _msg(64));
        assertEq(bytes(wall.messageOf(1)).length, 64);

        vm.prank(bob);
        wall.claim(2, _msg(1));
    }

    function test_lengthCountsBytesNotCharacters() public {
        // 16 four-byte emoji = 64 bytes: accepted. 17 = 68 bytes: refused.
        string memory bee = unicode"🐝";
        string memory s64;
        for (uint256 i; i < 16; ++i) {
            s64 = string.concat(s64, bee);
        }
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.MessageTooLong.selector, 68, 64));
        wall.claim(1, string.concat(s64, bee));
        vm.prank(alice);
        wall.claim(1, s64);
    }

    function testFuzz_messageLength(uint8 len) public {
        string memory m = _msg(len);
        vm.prank(alice);
        if (len == 0) {
            vm.expectRevert(CombWall.EmptyMessage.selector);
        } else if (len > 64) {
            vm.expectRevert(abi.encodeWithSelector(CombWall.MessageTooLong.selector, uint256(len), 64));
        }
        wall.claim(5, m);
    }

    // --- carve ---

    function test_carveCooldown() public {
        vm.prank(alice);
        wall.claim(9, "one");
        uint256 t0 = block.timestamp;
        assertEq(wall.nextCarveAt(9), t0 + 1 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.CarveCooldown.selector, t0 + 1 days));
        wall.carve("two");

        vm.warp(t0 + 1 days - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.CarveCooldown.selector, t0 + 1 days));
        wall.carve("two");

        vm.warp(t0 + 1 days);
        vm.expectEmit(address(wall));
        emit Carved(alice, 9, "two");
        vm.prank(alice);
        wall.carve("two");
        assertEq(wall.messageOf(9), "two");

        // cooldown restarts from the carve
        vm.warp(t0 + 2 days - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.CarveCooldown.selector, t0 + 2 days));
        wall.carve("three");
        vm.warp(t0 + 2 days);
        vm.prank(alice);
        wall.carve("three");
        assertEq(wall.messageOf(9), "three");
    }

    function test_carveWithoutCellReverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CombWall.NoCellHeld.selector, bob));
        wall.carve("hi");
    }

    function test_carveValidatesMessage() public {
        vm.prank(alice);
        wall.claim(9, "one");
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(alice);
        vm.expectRevert(CombWall.EmptyMessage.selector);
        wall.carve("");
        vm.expectRevert(abi.encodeWithSelector(CombWall.MessageTooLong.selector, 65, 64));
        wall.carve(_msg(65));
        vm.stopPrank();
        assertEq(wall.messageOf(9), "one");
    }

    function test_onlyHolderCarvesTheirOwnCell() public {
        vm.prank(alice);
        wall.claim(1, "alice");
        vm.prank(bob);
        wall.claim(2, "bob");
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        wall.carve("bob again");
        assertEq(wall.messageOf(1), "alice");
        assertEq(wall.messageOf(2), "bob again");
    }

    // --- release ---

    function test_releaseThenReclaim() public {
        vm.prank(alice);
        wall.claim(42, "alice was here");

        vm.expectEmit(address(wall));
        emit Released(alice, 42);
        vm.prank(alice);
        wall.release();
        assertEq(wall.ownerOf(42), address(0));
        assertEq(wall.messageOf(42), "");
        assertEq(wall.cellOf(alice), wall.NO_CELL());
        assertEq(wall.claimedCount(), 0);
        assertEq(wall.nextCarveAt(42), 0);

        vm.prank(bob);
        wall.claim(42, "bob now");
        assertEq(wall.ownerOf(42), bob);

        // alice may claim a different cell
        vm.prank(alice);
        wall.claim(43, "moved");
        assertEq(wall.cellOf(alice), 43);
        assertEq(wall.claimedCount(), 2);
    }

    function test_releaseWithoutCellReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.NoCellHeld.selector, alice));
        wall.release();
    }

    function test_releasedHolderCannotCarveOrReleaseAgain() public {
        vm.startPrank(alice);
        wall.claim(1, "x");
        wall.release();
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSelector(CombWall.NoCellHeld.selector, alice));
        wall.carve("y");
        vm.expectRevert(abi.encodeWithSelector(CombWall.NoCellHeld.selector, alice));
        wall.release();
        vm.stopPrank();
    }

    function test_newHolderGetsFreshCooldown() public {
        vm.prank(alice);
        wall.claim(1, "x");
        vm.prank(alice);
        wall.release();
        vm.warp(block.timestamp + 5 hours);
        vm.prank(bob);
        wall.claim(1, "y");
        assertEq(wall.nextCarveAt(1), block.timestamp + 1 days);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CombWall.CarveCooldown.selector, block.timestamp + 1 days));
        wall.carve("z");
    }

    // --- whole wall ---

    function test_all1024CellsClaimable() public {
        for (uint16 i; i < 1024; ++i) {
            address who = address(uint160(0x10000 + i));
            vm.prank(who);
            wall.claim(i, "cell");
            assertEq(wall.ownerOf(i), who);
            assertEq(wall.cellOf(who), i);
        }
        assertEq(wall.claimedCount(), 1024);

        address late = makeAddr("late");
        vm.prank(late);
        vm.expectRevert(
            abi.encodeWithSelector(CombWall.CellTaken.selector, uint16(500), address(uint160(0x10000 + 500)))
        );
        wall.claim(500, "full");

        (address[] memory owners, string[] memory messages) = wall.cells(1000, 100);
        assertEq(owners.length, 24);
        assertEq(owners[23], address(uint160(0x10000 + 1023)));
        assertEq(messages[0], "cell");
    }

    function test_cellsBatchView() public {
        vm.prank(alice);
        wall.claim(1, "a");
        (address[] memory owners, string[] memory messages) = wall.cells(0, 3);
        assertEq(owners.length, 3);
        assertEq(owners[0], address(0));
        assertEq(owners[1], alice);
        assertEq(messages[1], "a");
        assertEq(messages[2], "");
        vm.expectRevert(abi.encodeWithSelector(CombWall.InvalidCell.selector, uint16(1024)));
        wall.cells(1024, 1);
    }

    function test_viewsRejectOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(CombWall.InvalidCell.selector, uint16(1024)));
        wall.ownerOf(1024);
        vm.expectRevert(abi.encodeWithSelector(CombWall.InvalidCell.selector, uint16(1024)));
        wall.messageOf(1024);
        vm.expectRevert(abi.encodeWithSelector(CombWall.InvalidCell.selector, uint16(1024)));
        wall.nextCarveAt(1024);
    }

    // --- no ETH ---

    function test_rejectsEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(wall).call{value: 1 wei}("");
        assertFalse(ok);
        vm.prank(alice);
        (ok,) = address(wall).call{value: 1 wei}(abi.encodeCall(CombWall.claim, (1, "paid")));
        assertFalse(ok);
        assertEq(address(wall).balance, 0);
        assertEq(wall.ownerOf(1), address(0));
    }

    function test_noAdminSelectors() public {
        string[4] memory sigs = ["owner()", "pause()", "transferOwnership(address)", "upgradeTo(address)"];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(wall).call(abi.encodeWithSignature(sigs[i], alice));
            assertFalse(ok, sigs[i]);
        }
    }

    // --- invariant-style fuzz: counts stay consistent ---

    function testFuzz_claimReleaseSequence(uint256 seed) public {
        address[4] memory users = [alice, bob, makeAddr("c"), makeAddr("d")];
        uint256 held;
        for (uint256 step; step < 40; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address u = users[seed % 4];
            uint16 cell = uint16((seed >> 8) % 6);
            vm.startPrank(u);
            if (wall.hasCell(u)) {
                wall.release();
                held--;
            } else if (wall.ownerOf(cell) == address(0)) {
                wall.claim(cell, "f");
                held++;
            }
            vm.stopPrank();
            assertEq(wall.claimedCount(), held);
        }
        uint256 counted;
        for (uint16 i; i < 6; ++i) {
            address o = wall.ownerOf(i);
            if (o != address(0)) {
                counted++;
                assertEq(wall.cellOf(o), i);
            }
        }
        assertEq(counted, held);
    }
}
