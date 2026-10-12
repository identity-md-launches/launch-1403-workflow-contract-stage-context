// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CombWall} from "../src/CombWall.sol";

/// @dev Drives CombWall with random, bounded call sequences from several actors and keeps a ghost model of
/// what the wall should look like. Every target call is wrapped in try/catch and the outcome is compared
/// with the outcome the ghost model predicts, so an unexpected success or an unexpected revert fails the
/// run (the suite sets fail-on-revert, so an assertion inside the handler is not swallowed).
contract CombWallHandler is Test {
    CombWall public immutable wall;

    /// @dev Small id space so actors collide on cells and the wall saturates; `wide` claims use the full
    /// uint16 range so out-of-range ids and far-apart cells are exercised too.
    uint16 public constant CELL_SPACE = 6;
    uint256 public constant MAX_LEN_TRIED = 72;

    address[] public actors;

    // --- ghost model ---
    mapping(uint16 => address) public ghostOwner;
    mapping(uint16 => bytes) public ghostMessage;
    mapping(uint16 => uint256) public ghostLastWrite;
    mapping(address => uint16) public ghostCellPlusOne;
    uint256 public ghostHeld;
    /// @dev Every cell id a claim ever succeeded on. Only the handler reaches the wall, so a cell outside
    /// this list can never have been written: the invariants scan this list in full and sample the rest.
    uint16[] public touched;
    mapping(uint16 => bool) public isTouched;

    uint256 public ghostClaims;
    uint256 public ghostCarves;
    uint256 public ghostReleases;
    uint256 public ghostRevertedClaims;
    uint256 public ghostRevertedCarves;
    uint256 public ghostRevertedReleases;
    uint256 public ghostEthAttempts;

    constructor(CombWall wall_, uint256 actorCount) {
        wall = wall_;
        for (uint256 i; i < actorCount; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            vm.deal(a, 1 ether);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    // --- handlers ---

    function claim(uint256 actorSeed, uint16 cellId, uint256 lenSeed, bool wide) external {
        address actor = _actor(actorSeed);
        if (!wide) cellId = uint16(bound(cellId, 0, CELL_SPACE - 1));
        uint256 len = bound(lenSeed, 0, MAX_LEN_TRIED);
        bytes memory m = _message(len, lenSeed);

        bytes4 expected = _expectedClaimError(actor, cellId, len);

        vm.prank(actor);
        try wall.claim(cellId, string(m)) {
            assertEq(expected, bytes4(0), "claim succeeded but the model expected a revert");
            ghostOwner[cellId] = actor;
            ghostMessage[cellId] = m;
            ghostLastWrite[cellId] = block.timestamp;
            ghostCellPlusOne[actor] = cellId + 1;
            ++ghostHeld;
            ++ghostClaims;
            if (!isTouched[cellId]) {
                isTouched[cellId] = true;
                touched.push(cellId);
            }
        } catch (bytes memory err) {
            assertTrue(expected != bytes4(0), "claim reverted but the model expected success");
            assertEq(bytes4(err), expected, "claim reverted with an unexpected error");
            ++ghostRevertedClaims;
        }
    }

    function carve(uint256 actorSeed, uint256 lenSeed) external {
        address actor = _actor(actorSeed);
        uint256 len = bound(lenSeed, 0, MAX_LEN_TRIED);
        bytes memory m = _message(len, lenSeed);

        bytes4 expected = _expectedCarveError(actor, len);
        uint16 cellId = ghostCellPlusOne[actor] == 0 ? 0 : ghostCellPlusOne[actor] - 1;

        vm.prank(actor);
        try wall.carve(string(m)) {
            assertEq(expected, bytes4(0), "carve succeeded but the model expected a revert");
            ghostMessage[cellId] = m;
            ghostLastWrite[cellId] = block.timestamp;
            ++ghostCarves;
        } catch (bytes memory err) {
            assertTrue(expected != bytes4(0), "carve reverted but the model expected success");
            assertEq(bytes4(err), expected, "carve reverted with an unexpected error");
            ++ghostRevertedCarves;
        }
    }

    function release(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint16 held = ghostCellPlusOne[actor];

        vm.prank(actor);
        try wall.release() {
            assertTrue(held != 0, "release succeeded for an actor that holds nothing");
            uint16 cellId = held - 1;
            delete ghostOwner[cellId];
            delete ghostMessage[cellId];
            delete ghostLastWrite[cellId];
            delete ghostCellPlusOne[actor];
            --ghostHeld;
            ++ghostReleases;
        } catch (bytes memory err) {
            assertTrue(held == 0, "release reverted for an actor that holds a cell");
            assertEq(bytes4(err), CombWall.NoCellHeld.selector, "release reverted with an unexpected error");
            ++ghostRevertedReleases;
        }
    }

    /// @dev Advances time so the 24 h cooldown is crossed in some sequences and not in others.
    function warp(uint256 delta) external {
        delta = bound(delta, 0, 36 hours);
        vm.warp(block.timestamp + delta);
    }

    /// @dev Boundary stress: jump to exactly the holder's cooldown, or one second before it, and carve.
    /// Random warps rarely land on the second that matters; this handler makes sure every run does.
    function carveAtCooldownEdge(uint256 actorSeed, uint256 lenSeed, bool oneSecondEarly) external {
        address actor = _actor(actorSeed);
        uint16 held = ghostCellPlusOne[actor];
        if (held != 0) {
            uint256 edge = ghostLastWrite[held - 1] + wall.CARVE_COOLDOWN() - (oneSecondEarly ? 1 : 0);
            if (edge > block.timestamp) vm.warp(edge);
        }
        this.carve(actorSeed, lenSeed);
    }

    /// @dev ETH must never enter the wall, by plain transfer or alongside a function call.
    function sendEth(uint256 actorSeed, uint256 amount, bool withCall) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 0.1 ether);
        vm.deal(actor, amount);
        bytes memory data = withCall ? abi.encodeCall(CombWall.claim, (uint16(0), "paid")) : bytes("");
        vm.prank(actor);
        (bool ok,) = address(wall).call{value: amount}(data);
        assertFalse(ok, "the wall accepted ETH");
        ++ghostEthAttempts;
    }

    // --- model ---

    function _expectedClaimError(address actor, uint16 cellId, uint256 len) private view returns (bytes4) {
        if (cellId >= wall.CELL_COUNT()) return CombWall.InvalidCell.selector;
        if (ghostCellPlusOne[actor] != 0) return CombWall.AlreadyHoldsCell.selector;
        if (ghostOwner[cellId] != address(0)) return CombWall.CellTaken.selector;
        if (len == 0) return CombWall.EmptyMessage.selector;
        if (len > wall.MAX_MESSAGE_BYTES()) return CombWall.MessageTooLong.selector;
        return bytes4(0);
    }

    function _expectedCarveError(address actor, uint256 len) private view returns (bytes4) {
        uint16 held = ghostCellPlusOne[actor];
        if (held == 0) return CombWall.NoCellHeld.selector;
        if (block.timestamp < ghostLastWrite[held - 1] + wall.CARVE_COOLDOWN()) return CombWall.CarveCooldown.selector;
        if (len == 0) return CombWall.EmptyMessage.selector;
        if (len > wall.MAX_MESSAGE_BYTES()) return CombWall.MessageTooLong.selector;
        return bytes4(0);
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// @dev Arbitrary bytes, including 0x00 and 0xff: the wall stores raw bytes, not validated text.
    function _message(uint256 len, uint256 seed) private pure returns (bytes memory m) {
        m = new bytes(len);
        for (uint256 i; i < len; ++i) {
            m[i] = bytes1(uint8(uint256(keccak256(abi.encode(seed, i)))));
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract CombWallInvariantTest is Test {
    CombWall wall;
    CombWallHandler handler;

    uint256 constant ACTORS = 8;

    function setUp() public {
        vm.warp(1_700_000_000);
        wall = new CombWall();
        handler = new CombWallHandler(wall, ACTORS);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = CombWallHandler.claim.selector;
        selectors[1] = CombWallHandler.carve.selector;
        selectors[2] = CombWallHandler.release.selector;
        selectors[3] = CombWallHandler.warp.selector;
        selectors[4] = CombWallHandler.sendEth.selector;
        selectors[5] = CombWallHandler.carveAtCooldownEdge.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev claimedCount is exactly the number of occupied cells, and equals claims minus releases.
    function invariant_claimedCountMatchesModel() public view {
        assertEq(wall.claimedCount(), handler.ghostHeld(), "claimedCount != ghost held");
        assertEq(handler.ghostClaims() - handler.ghostReleases(), wall.claimedCount(), "claims - releases != held");
        assertLe(wall.claimedCount(), ACTORS, "more cells held than actors exist");
        assertLe(wall.claimedCount(), wall.CELL_COUNT(), "more cells held than exist");
    }

    /// @dev Every cell a claim ever landed on matches the ghost model: occupied cells carry the exact bytes
    /// and cooldown the model recorded and point back at a holder whose reverse lookup agrees; released
    /// cells are really empty; no wallet appears in two cells; the occupied count is claimedCount.
    function invariant_touchedCellsMatchModel() public view {
        uint256 n = handler.touchedCount();
        uint256 occupied;
        address[] memory seen = new address[](n);
        for (uint256 i; i < n; ++i) {
            uint16 id = handler.touched(i);
            address owner = wall.ownerOf(id);
            bytes memory message = bytes(wall.messageOf(id));
            assertEq(owner, handler.ghostOwner(id), "owner != ghost owner");
            assertEq(message, handler.ghostMessage(id), "message != ghost message");

            if (owner == address(0)) {
                assertEq(message.length, 0, "empty cell has a message");
                assertEq(wall.nextCarveAt(id), 0, "empty cell has a cooldown");
                continue;
            }

            assertGe(message.length, 1, "held cell has an empty message");
            assertLe(message.length, wall.MAX_MESSAGE_BYTES(), "held cell message too long");
            assertEq(wall.cellOf(owner), id, "cellOf(owner) != cell");
            assertTrue(wall.hasCell(owner), "holder reported as holding nothing");
            assertEq(wall.nextCarveAt(id), handler.ghostLastWrite(id) + wall.CARVE_COOLDOWN(), "nextCarveAt != ghost");
            for (uint256 j; j < occupied; ++j) {
                assertTrue(seen[j] != owner, "one wallet holds two cells");
            }
            seen[occupied++] = owner;
        }
        assertEq(occupied, wall.claimedCount(), "occupied touched cells != claimedCount");
    }

    /// @dev The batch view agrees with the single-cell views over a window that includes the small id
    /// space every run hammers, and cells no claim ever landed on stay empty (sampled across the wall).
    function invariant_batchViewAgreesAndUntouchedCellsStayEmpty() public view {
        uint16 window = handler.CELL_SPACE() + 2;
        (address[] memory owners, string[] memory messages) = wall.cells(0, window);
        assertEq(owners.length, window, "batch view length");
        for (uint256 i; i < window; ++i) {
            uint16 id = uint16(i);
            assertEq(owners[i], handler.ghostOwner(id), "batch owner != ghost");
            assertEq(bytes(messages[i]), handler.ghostMessage(id), "batch message != ghost");
        }
        // eight samples spread over the wall, shifted by the call count so runs sample different cells
        uint256 shift = handler.ghostClaims() + handler.ghostRevertedClaims();
        for (uint256 k; k < 8; ++k) {
            uint16 id = uint16((window + k * 127 + shift * 13) % wall.CELL_COUNT());
            if (id < window || handler.isTouched(id)) continue;
            assertEq(wall.ownerOf(id), address(0), "untouched cell has an owner");
            assertEq(bytes(wall.messageOf(id)).length, 0, "untouched cell has a message");
            assertEq(wall.nextCarveAt(id), 0, "untouched cell has a cooldown");
        }
    }

    /// @dev The reverse mapping for every actor agrees with the ghost model and with the forward mapping.
    function invariant_actorsConsistent() public view {
        for (uint256 i; i < ACTORS; ++i) {
            address a = handler.actors(i);
            uint16 held = handler.ghostCellPlusOne(a);
            if (held == 0) {
                assertFalse(wall.hasCell(a), "actor without cell reported as holder");
                assertEq(wall.cellOf(a), wall.NO_CELL(), "actor without cell has a cell id");
            } else {
                assertTrue(wall.hasCell(a), "holder reported as having nothing");
                assertEq(wall.cellOf(a), held - 1, "cellOf != ghost");
                assertEq(wall.ownerOf(held - 1), a, "ownerOf(cellOf(a)) != a");
            }
        }
    }

    /// @dev The wall holds no ETH, ever.
    function invariant_noEther() public view {
        assertEq(address(wall).balance, 0, "the wall holds ETH");
    }

    /// @dev The handler must have driven both the success and the failure paths or the run proved
    /// nothing. Checked as an invariant so a vacuous campaign is reported rather than silently green.
    function invariant_campaignIsNotVacuous() public view {
        // After the first few calls of any run some claim must have succeeded; a tiny sequence may not
        // reach the failure paths yet, so only the ratio-free sanity check is asserted here.
        if (handler.ghostClaims() + handler.ghostRevertedClaims() >= 16) {
            assertGt(handler.ghostClaims(), 0, "no claim ever succeeded");
            assertGt(handler.ghostRevertedClaims(), 0, "no claim ever reverted");
        }
    }
}
