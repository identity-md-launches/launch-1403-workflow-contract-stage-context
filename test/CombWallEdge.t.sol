// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CombWall} from "../src/CombWall.sol";

/// @dev Adversarial and boundary cases for CombWall that the base suite does not pin: the batch view at its
/// edges, fuzzed ids and cooldown offsets, raw-byte messages, error precedence, failed calls leaving no
/// trace, and the shapes of admin / value-accepting entry points that must not exist.
/// forge-config: default.fuzz.runs = 1000
contract CombWallEdgeTest is Test {
    CombWall wall;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant T0 = 1_700_000_000;

    event Claimed(address indexed owner, uint16 indexed cellId, string message);
    event Carved(address indexed owner, uint16 indexed cellId, string message);
    event Released(address indexed owner, uint16 indexed cellId);

    function setUp() public {
        vm.warp(T0);
        wall = new CombWall();
    }

    function _msg(uint256 len) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i; i < len; ++i) {
            b[i] = bytes1(uint8(0x61 + (i % 26)));
        }
        return string(b);
    }

    // --- constants are what the brief says ---

    function test_constants() public view {
        assertEq(wall.CELL_COUNT(), 1024);
        assertEq(wall.MAX_MESSAGE_BYTES(), 64);
        assertEq(wall.CARVE_COOLDOWN(), 24 hours);
        assertEq(wall.NO_CELL(), type(uint16).max);
        // NO_CELL can never collide with a real id
        assertGe(wall.NO_CELL(), wall.CELL_COUNT());
    }

    // --- batch view edges ---

    function test_cellsCountZeroReturnsEmptyArrays() public view {
        (address[] memory owners, string[] memory messages) = wall.cells(0, 0);
        assertEq(owners.length, 0);
        assertEq(messages.length, 0);
        (owners, messages) = wall.cells(1023, 0);
        assertEq(owners.length, 0);
    }

    function test_cellsFromLastCellWithMaxCount() public {
        vm.prank(alice);
        wall.claim(1023, "edge");
        (address[] memory owners, string[] memory messages) = wall.cells(1023, type(uint16).max);
        assertEq(owners.length, 1);
        assertEq(owners[0], alice);
        assertEq(messages[0], "edge");
    }

    function test_cellsWholeWallInOneCall() public view {
        (address[] memory owners, string[] memory messages) = wall.cells(0, 1024);
        assertEq(owners.length, 1024);
        assertEq(messages.length, 1024);
        (owners,) = wall.cells(0, type(uint16).max);
        assertEq(owners.length, 1024);
    }

    function testFuzz_cellsLengthIsTruncatedAtTheWall(uint16 from, uint16 count) public {
        if (from >= 1024) {
            vm.expectRevert(abi.encodeWithSelector(CombWall.InvalidCell.selector, from));
            wall.cells(from, count);
            return;
        }
        (address[] memory owners, string[] memory messages) = wall.cells(from, count);
        uint256 expected = uint256(from) + count > 1024 ? 1024 - from : count;
        assertEq(owners.length, expected);
        assertEq(messages.length, expected);
    }

    function testFuzz_cellsAgreesWithSingleViews(uint16 from, uint8 count) public {
        from = uint16(bound(from, 0, 1023));
        // populate a few cells around `from`
        for (uint256 i; i < 3; ++i) {
            uint16 id = uint16((uint256(from) + i * 7) % 1024);
            address who = address(uint160(0xA000 + i));
            vm.prank(who);
            wall.claim(id, string.concat("m", vm.toString(i)));
        }
        (address[] memory owners, string[] memory messages) = wall.cells(from, count);
        for (uint256 i; i < owners.length; ++i) {
            uint16 id = uint16(from + i);
            assertEq(owners[i], wall.ownerOf(id));
            assertEq(messages[i], wall.messageOf(id));
        }
    }

    // --- ids ---

    function testFuzz_claimOutOfRangeAlwaysReverts(uint16 cellId) public {
        cellId = uint16(bound(cellId, 1024, type(uint16).max));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.InvalidCell.selector, cellId));
        wall.claim(cellId, "x");
        assertFalse(wall.hasCell(alice));
        assertEq(wall.claimedCount(), 0);
    }

    function testFuzz_claimAnyValidCell(uint16 cellId) public {
        cellId = uint16(bound(cellId, 0, 1023));
        vm.expectEmit(address(wall));
        emit Claimed(alice, cellId, "x");
        vm.prank(alice);
        wall.claim(cellId, "x");
        assertEq(wall.ownerOf(cellId), alice);
        assertEq(wall.cellOf(alice), cellId);
        assertEq(wall.nextCarveAt(cellId), T0 + 24 hours);
        assertEq(wall.claimedCount(), 1);
    }

    function testFuzz_secondClaimRevertsWhateverTheTarget(uint16 first, uint16 second) public {
        first = uint16(bound(first, 0, 1023));
        vm.prank(alice);
        wall.claim(first, "one");
        // whether `second` is free, the same cell, or out of range, the holder is refused
        vm.prank(alice);
        if (second >= 1024) {
            vm.expectRevert(abi.encodeWithSelector(CombWall.InvalidCell.selector, second));
        } else {
            vm.expectRevert(abi.encodeWithSelector(CombWall.AlreadyHoldsCell.selector, alice, first));
        }
        wall.claim(second, "two");
        assertEq(wall.cellOf(alice), first);
        assertEq(wall.claimedCount(), 1);
    }

    function testFuzz_twoWalletsCannotShareACell(uint16 cellId) public {
        cellId = uint16(bound(cellId, 0, 1023));
        vm.prank(alice);
        wall.claim(cellId, "a");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CombWall.CellTaken.selector, cellId, alice));
        wall.claim(cellId, "b");
        assertFalse(wall.hasCell(bob));
        assertEq(wall.ownerOf(cellId), alice);
        assertEq(wall.messageOf(cellId), "a");
    }

    // --- error precedence: the id is checked before anything else ---

    function test_invalidIdWinsOverEveryOtherError() public {
        vm.prank(alice);
        wall.claim(1, "held");
        // alice holds a cell AND sends an empty message, but the id is what is reported
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.InvalidCell.selector, uint16(1024)));
        wall.claim(1024, "");
    }

    function test_holderCheckWinsOverTakenAndMessage() public {
        vm.prank(alice);
        wall.claim(1, "held");
        vm.prank(bob);
        wall.claim(2, "bob");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.AlreadyHoldsCell.selector, alice, uint16(1)));
        wall.claim(2, "");
    }

    function test_takenCheckWinsOverMessage() public {
        vm.prank(alice);
        wall.claim(1, "held");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CombWall.CellTaken.selector, uint16(1), alice));
        wall.claim(1, "");
    }

    function test_cooldownCheckWinsOverMessage() public {
        vm.prank(alice);
        wall.claim(1, "held");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.CarveCooldown.selector, T0 + 24 hours));
        wall.carve("");
    }

    // --- failed calls leave no trace ---

    function test_failedClaimLeavesNothingBehind() public {
        vm.prank(alice);
        vm.expectRevert(CombWall.EmptyMessage.selector);
        wall.claim(5, "");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.MessageTooLong.selector, 65, 64));
        wall.claim(5, _msg(65));
        assertEq(wall.ownerOf(5), address(0));
        assertEq(wall.messageOf(5), "");
        assertEq(wall.nextCarveAt(5), 0);
        assertFalse(wall.hasCell(alice));
        assertEq(wall.cellOf(alice), wall.NO_CELL());
        assertEq(wall.claimedCount(), 0);
        // the cell is still claimable by anyone
        vm.prank(bob);
        wall.claim(5, "ok");
    }

    function test_failedCarveDoesNotResetCooldownOrMessage() public {
        vm.prank(alice);
        wall.claim(5, "orig");
        vm.warp(T0 + 24 hours);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.MessageTooLong.selector, 65, 64));
        wall.carve(_msg(65));
        assertEq(wall.messageOf(5), "orig");
        assertEq(wall.nextCarveAt(5), T0 + 24 hours);
        // and a valid carve in the same block still works
        vm.prank(alice);
        wall.carve("new");
        assertEq(wall.messageOf(5), "new");
        assertEq(wall.nextCarveAt(5), T0 + 48 hours);
    }

    // --- cooldown ---

    function testFuzz_carveAllowedExactlyFromTheCooldown(uint256 delta) public {
        delta = bound(delta, 0, 3 days);
        vm.prank(alice);
        wall.claim(9, "one");
        vm.warp(T0 + delta);
        vm.prank(alice);
        if (delta < 24 hours) {
            vm.expectRevert(abi.encodeWithSelector(CombWall.CarveCooldown.selector, T0 + 24 hours));
            wall.carve("two");
            assertEq(wall.messageOf(9), "one");
            assertEq(wall.nextCarveAt(9), T0 + 24 hours);
        } else {
            wall.carve("two");
            assertEq(wall.messageOf(9), "two");
            assertEq(wall.nextCarveAt(9), T0 + delta + 24 hours);
        }
    }

    function testFuzz_cooldownIsMeasuredFromTheLastWriteNotTheClaim(uint256 d1, uint256 d2) public {
        d1 = bound(d1, 24 hours, 10 days);
        d2 = bound(d2, 0, 24 hours - 1);
        vm.prank(alice);
        wall.claim(9, "one");
        vm.warp(T0 + d1);
        vm.prank(alice);
        wall.carve("two");
        vm.warp(T0 + d1 + d2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.CarveCooldown.selector, T0 + d1 + 24 hours));
        wall.carve("three");
    }

    function test_cooldownDoesNotLeakBetweenHolders() public {
        vm.prank(alice);
        wall.claim(9, "a");
        vm.warp(T0 + 24 hours);
        vm.prank(alice);
        wall.carve("a2");
        vm.prank(alice);
        wall.release();
        // bob claims the just-released cell: a fresh cooldown from his own claim, not from alice's carve
        vm.prank(bob);
        wall.claim(9, "b");
        assertEq(wall.nextCarveAt(9), T0 + 48 hours);
        vm.warp(T0 + 48 hours - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CombWall.CarveCooldown.selector, T0 + 48 hours));
        wall.carve("b2");
        // alice, now cell-less, cannot touch cell 9 either
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.NoCellHeld.selector, alice));
        wall.carve("a3");
    }

    /// @dev Documented in the README: release + reclaim is a fresh claim and carries no cooldown. Pinned
    /// here so the behaviour is explicit; see the findings file for the note that this sidesteps the
    /// "once every 24 hours" rewrite rule when the holder is willing to risk losing the cell.
    function test_releaseAndReclaimRewritesWithoutCooldown() public {
        vm.startPrank(alice);
        wall.claim(9, "one");
        wall.release();
        wall.claim(9, "two");
        vm.stopPrank();
        assertEq(wall.messageOf(9), "two");
        assertEq(wall.ownerOf(9), alice);
        assertEq(wall.claimedCount(), 1);
    }

    // --- messages are raw bytes ---

    function test_messageStoresRawBytesVerbatim() public {
        bytes memory raw = new bytes(64);
        for (uint256 i; i < 64; ++i) {
            raw[i] = bytes1(uint8(i * 4)); // includes 0x00 and high bytes, not valid UTF-8
        }
        raw[63] = 0xff;
        vm.prank(alice);
        wall.claim(3, string(raw));
        assertEq(bytes(wall.messageOf(3)), raw);
        (, string[] memory messages) = wall.cells(3, 1);
        assertEq(bytes(messages[0]), raw);
    }

    function testFuzz_messageRoundTrips(bytes memory raw) public {
        uint256 len = bound(raw.length, 1, 64);
        bytes memory m = new bytes(len);
        for (uint256 i; i < len; ++i) {
            m[i] = i < raw.length ? raw[i] : bytes1(uint8(i));
        }
        vm.prank(alice);
        wall.claim(3, string(m));
        assertEq(bytes(wall.messageOf(3)), m);
    }

    function testFuzz_carveMessageLength(uint8 len) public {
        vm.prank(alice);
        wall.claim(3, "x");
        vm.warp(T0 + 24 hours);
        string memory m = _msg(len);
        vm.prank(alice);
        if (len == 0) {
            vm.expectRevert(CombWall.EmptyMessage.selector);
        } else if (len > 64) {
            vm.expectRevert(abi.encodeWithSelector(CombWall.MessageTooLong.selector, uint256(len), 64));
        }
        wall.carve(m);
        if (len >= 1 && len <= 64) assertEq(wall.messageOf(3), m);
        else assertEq(wall.messageOf(3), "x");
    }

    // --- release ---

    function test_releaseOnlyTouchesTheCallersCell() public {
        vm.prank(alice);
        wall.claim(1, "a");
        vm.prank(bob);
        wall.claim(2, "b");
        vm.prank(carol);
        wall.claim(3, "c");
        vm.prank(bob);
        wall.release();
        assertEq(wall.ownerOf(1), alice);
        assertEq(wall.messageOf(1), "a");
        assertEq(wall.ownerOf(2), address(0));
        assertEq(wall.messageOf(2), "");
        assertEq(wall.ownerOf(3), carol);
        assertEq(wall.claimedCount(), 2);
        assertTrue(wall.hasCell(alice));
        assertFalse(wall.hasCell(bob));
        assertTrue(wall.hasCell(carol));
    }

    function test_releaseCellZero() public {
        vm.prank(alice);
        wall.claim(0, "zero");
        vm.prank(alice);
        wall.release();
        assertEq(wall.ownerOf(0), address(0));
        assertEq(wall.cellOf(alice), wall.NO_CELL());
        assertFalse(wall.hasCell(alice));
        assertEq(wall.claimedCount(), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.NoCellHeld.selector, alice));
        wall.release();
    }

    function test_doubleReleaseInOneSequenceReverts() public {
        vm.startPrank(alice);
        wall.claim(7, "x");
        wall.release();
        vm.expectRevert(abi.encodeWithSelector(CombWall.NoCellHeld.selector, alice));
        wall.release();
        vm.stopPrank();
        assertEq(wall.claimedCount(), 0);
    }

    function test_claimReleaseCyclesKeepCountExact() public {
        for (uint256 round; round < 5; ++round) {
            for (uint16 i; i < 10; ++i) {
                vm.prank(address(uint160(0xB000 + i)));
                wall.claim(i, "r");
            }
            assertEq(wall.claimedCount(), 10);
            for (uint16 i; i < 10; ++i) {
                vm.prank(address(uint160(0xB000 + i)));
                wall.release();
            }
            assertEq(wall.claimedCount(), 0);
        }
    }

    // --- events ---

    function test_eventsCarryTheRightArguments() public {
        vm.expectEmit(address(wall));
        emit Claimed(alice, 100, "hi");
        vm.prank(alice);
        wall.claim(100, "hi");

        vm.warp(T0 + 24 hours);
        vm.expectEmit(address(wall));
        emit Carved(alice, 100, "again");
        vm.prank(alice);
        wall.carve("again");

        vm.expectEmit(address(wall));
        emit Released(alice, 100);
        vm.prank(alice);
        wall.release();
    }

    // --- surface that must not exist ---

    function test_noPrivilegedOrValueEntryPoints() public {
        string[12] memory sigs = [
            "owner()",
            "renounceOwnership()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize()",
            "setMessage(uint16,string)",
            "clear(uint16)",
            "setCooldown(uint256)",
            "withdraw()"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(wall).call(abi.encodeWithSignature(sigs[i], alice));
            assertFalse(ok, sigs[i]);
        }
        // no receive / fallback: empty calldata and unknown selectors both revert
        (bool ok2,) = address(wall).call("");
        assertFalse(ok2, "empty calldata accepted");
        (ok2,) = address(wall).call(hex"deadbeef");
        assertFalse(ok2, "unknown selector accepted");
    }

    function testFuzz_valueIsRefusedOnEveryFunction(uint8 which, uint96 value) public {
        value = uint96(bound(value, 1, type(uint96).max));
        vm.deal(alice, value);
        bytes[3] memory calls = [
            abi.encodeCall(CombWall.claim, (uint16(1), "paid")),
            abi.encodeCall(CombWall.carve, ("paid")),
            abi.encodeCall(CombWall.release, ())
        ];
        vm.prank(alice);
        (bool ok,) = address(wall).call{value: value}(calls[which % 3]);
        assertFalse(ok);
        assertEq(address(wall).balance, 0);
        assertEq(alice.balance, value);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory code = address(wall).code;
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

    // --- whole-wall saturation ---

    function test_fullWallRefusesEveryIdAndFreesOnRelease() public {
        for (uint16 i; i < 1024; ++i) {
            vm.prank(address(uint160(0x20000 + i)));
            wall.claim(i, "c");
        }
        assertEq(wall.claimedCount(), 1024);
        // a newcomer finds every cell taken, including the first and the last
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CombWall.CellTaken.selector, uint16(0), address(uint160(0x20000))));
        wall.claim(0, "late");
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CombWall.CellTaken.selector, uint16(1023), address(uint160(0x20000 + 1023)))
        );
        wall.claim(1023, "late");
        // one release frees exactly one cell
        vm.prank(address(uint160(0x20000 + 512)));
        wall.release();
        assertEq(wall.claimedCount(), 1023);
        vm.prank(alice);
        wall.claim(512, "mine now");
        assertEq(wall.claimedCount(), 1024);
        assertEq(wall.ownerOf(512), alice);
    }
}
