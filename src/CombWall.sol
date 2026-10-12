// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title CombWall — the last wall of the hive
/// @notice 1,024 cells (ids 0..1023). Any wallet may hold at most one cell at a time and carve a message of
/// 1 to 64 bytes into it. The holder can rewrite the message at most once every 24 hours (measured from the
/// last write, claim included) and can release the cell, which empties it for anyone to claim.
/// @dev No owner, no admin, no pause, no upgrade, no external calls, no payable functions (ETH is refused).
contract CombWall {
    uint16 public constant CELL_COUNT = 1024;
    uint256 public constant MAX_MESSAGE_BYTES = 64;
    uint256 public constant CARVE_COOLDOWN = 24 hours;
    /// @notice Returned by `cellOf` for a wallet that holds no cell.
    uint16 public constant NO_CELL = type(uint16).max;

    struct Cell {
        address owner;
        uint64 lastWrite;
        string message;
    }

    mapping(uint16 => Cell) private _cells;
    /// @dev Cell id + 1 for a holder, 0 for none.
    mapping(address => uint16) private _cellPlusOne;
    uint16 private _claimed;

    event Claimed(address indexed owner, uint16 indexed cellId, string message);
    event Carved(address indexed owner, uint16 indexed cellId, string message);
    event Released(address indexed owner, uint16 indexed cellId);

    error InvalidCell(uint16 cellId);
    error CellTaken(uint16 cellId, address owner);
    error AlreadyHoldsCell(address account, uint16 cellId);
    error NoCellHeld(address account);
    error EmptyMessage();
    error MessageTooLong(uint256 length, uint256 max);
    error CarveCooldown(uint256 availableAt);

    /// @notice Claim the empty cell `cellId` and carve `message` into it.
    function claim(uint16 cellId, string calldata message) external {
        if (cellId >= CELL_COUNT) revert InvalidCell(cellId);
        uint16 held = _cellPlusOne[msg.sender];
        if (held != 0) revert AlreadyHoldsCell(msg.sender, held - 1);
        Cell storage cell = _cells[cellId];
        if (cell.owner != address(0)) revert CellTaken(cellId, cell.owner);
        _checkMessage(message);

        cell.owner = msg.sender;
        cell.lastWrite = uint64(block.timestamp);
        cell.message = message;
        _cellPlusOne[msg.sender] = cellId + 1;
        unchecked {
            ++_claimed;
        }
        emit Claimed(msg.sender, cellId, message);
    }

    /// @notice Rewrite the caller's message. Allowed once `CARVE_COOLDOWN` has passed since the last write.
    function carve(string calldata message) external {
        uint16 cellId = _heldCell(msg.sender);
        Cell storage cell = _cells[cellId];
        uint256 availableAt = uint256(cell.lastWrite) + CARVE_COOLDOWN;
        if (block.timestamp < availableAt) revert CarveCooldown(availableAt);
        _checkMessage(message);

        cell.lastWrite = uint64(block.timestamp);
        cell.message = message;
        emit Carved(msg.sender, cellId, message);
    }

    /// @notice Give up the caller's cell. It becomes empty (message cleared) and claimable again.
    function release() external {
        uint16 cellId = _heldCell(msg.sender);
        delete _cells[cellId];
        delete _cellPlusOne[msg.sender];
        unchecked {
            --_claimed;
        }
        emit Released(msg.sender, cellId);
    }

    /// @notice The cell `account` holds, or `NO_CELL` (65535) when it holds none.
    function cellOf(address account) external view returns (uint16) {
        uint16 held = _cellPlusOne[account];
        return held == 0 ? NO_CELL : held - 1;
    }

    /// @notice Whether `account` holds a cell.
    function hasCell(address account) external view returns (bool) {
        return _cellPlusOne[account] != 0;
    }

    /// @notice Holder of `cellId`, or the zero address when empty. Reverts for ids outside 0..1023.
    function ownerOf(uint16 cellId) external view returns (address) {
        if (cellId >= CELL_COUNT) revert InvalidCell(cellId);
        return _cells[cellId].owner;
    }

    /// @notice Message of `cellId`, or "" when empty. Reverts for ids outside 0..1023.
    function messageOf(uint16 cellId) external view returns (string memory) {
        if (cellId >= CELL_COUNT) revert InvalidCell(cellId);
        return _cells[cellId].message;
    }

    /// @notice Earliest timestamp at which the holder of `cellId` may carve again (0 when empty).
    function nextCarveAt(uint16 cellId) external view returns (uint256) {
        if (cellId >= CELL_COUNT) revert InvalidCell(cellId);
        Cell storage cell = _cells[cellId];
        return cell.owner == address(0) ? 0 : uint256(cell.lastWrite) + CARVE_COOLDOWN;
    }

    /// @notice Number of cells currently held.
    function claimedCount() external view returns (uint256) {
        return _claimed;
    }

    /// @notice Batch read for frontends: owners and messages of cells `from` .. `from + count - 1`,
    /// truncated at the last cell.
    function cells(uint16 from, uint16 count)
        external
        view
        returns (address[] memory owners, string[] memory messages)
    {
        if (from >= CELL_COUNT) revert InvalidCell(from);
        uint256 end = uint256(from) + count;
        if (end > CELL_COUNT) end = CELL_COUNT;
        uint256 n = end - from;
        owners = new address[](n);
        messages = new string[](n);
        for (uint256 i; i < n; ++i) {
            Cell storage cell = _cells[uint16(from + i)];
            owners[i] = cell.owner;
            messages[i] = cell.message;
        }
    }

    function _heldCell(address account) private view returns (uint16) {
        uint16 held = _cellPlusOne[account];
        if (held == 0) revert NoCellHeld(account);
        return held - 1;
    }

    function _checkMessage(string calldata message) private pure {
        uint256 len = bytes(message).length;
        if (len == 0) revert EmptyMessage();
        if (len > MAX_MESSAGE_BYTES) revert MessageTooLong(len, MAX_MESSAGE_BYTES);
    }
}
