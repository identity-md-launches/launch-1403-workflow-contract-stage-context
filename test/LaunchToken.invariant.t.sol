// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @dev Deploys the token (so it is the deployer that receives the supply), spreads part of it over a set
/// of actors and then drives transfer / approve / transferFrom with bounded inputs. A ghost ledger of
/// balances and allowances predicts every outcome; a success the ledger did not predict, or a revert it
/// did not predict, fails the run.
contract LaunchTokenHandler is Test {
    LaunchToken public immutable token;
    address[] public holders; // every address that can ever hold tokens: the actors and this handler

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostTransfers;
    uint256 public ghostRevertedTransfers;
    uint256 public ghostTransferFroms;
    uint256 public ghostRevertedTransferFroms;
    uint256 public ghostApprovals;
    uint256 public ghostRevertedApprovals;

    constructor(uint256 actorCount) {
        token = new LaunchToken();
        holders.push(address(this));
        ghostBalance[address(this)] = token.TOTAL_SUPPLY();
        for (uint256 i; i < actorCount; ++i) {
            address a = makeAddr(string.concat("holder", vm.toString(i)));
            holders.push(a);
            uint256 seed = token.TOTAL_SUPPLY() / (actorCount * 4);
            token.transfer(a, seed);
            ghostBalance[address(this)] -= seed;
            ghostBalance[a] += seed;
        }
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    // --- handlers ---

    /// @param mode 0: amount within balance; 1: full balance; 2: balance + 1 (must revert);
    ///             3: to the zero address (must revert); 4: self-transfer.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount, uint8 mode) external {
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        mode = uint8(bound(mode, 0, 4));
        uint256 bal = ghostBalance[from];
        if (mode == 0) {
            amount = bound(amount, 0, bal);
        } else if (mode == 1) {
            amount = bal;
        } else if (mode == 2) {
            amount = bal + 1;
        } else if (mode == 3) {
            amount = bound(amount, 0, bal);
            to = address(0);
        } else {
            amount = bound(amount, 0, bal);
            to = from;
        }

        bytes4 expected = _expectedTransferError(from, to, amount);

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            assertTrue(ok, "transfer returned false");
            assertEq(expected, bytes4(0), "transfer succeeded but the ledger expected a revert");
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            ++ghostTransfers;
        } catch (bytes memory err) {
            assertTrue(expected != bytes4(0), "transfer reverted but the ledger expected success");
            assertEq(bytes4(err), expected, "transfer reverted with an unexpected error");
            ++ghostRevertedTransfers;
        }
    }

    /// @param mode 0: bounded amount; 1: infinite; 2: zero; 3: zero spender (must revert).
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, uint8 mode) external {
        address owner = _holder(ownerSeed);
        address spender = _holder(spenderSeed);
        mode = uint8(bound(mode, 0, 3));
        if (mode == 0) amount = bound(amount, 0, token.TOTAL_SUPPLY() * 2);
        else if (mode == 1) amount = type(uint256).max;
        else if (mode == 2) amount = 0;
        else spender = address(0);

        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            assertTrue(ok, "approve returned false");
            assertTrue(spender != address(0), "approve of the zero spender succeeded");
            ghostAllowance[owner][spender] = amount;
            ++ghostApprovals;
        } catch (bytes memory err) {
            assertTrue(spender == address(0), "approve reverted for a valid spender");
            assertEq(bytes4(err), LaunchToken.InvalidAddress.selector, "approve reverted with an unexpected error");
            ++ghostRevertedApprovals;
        }
    }

    /// @param mode 0: within min(allowance, balance); 1: allowance + 1 (reverts unless infinite);
    ///             2: balance + 1 (must revert); 3: to the zero address (must revert); 4: exact allowance.
    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount, uint8 mode) external {
        address spender = _holder(spenderSeed);
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        mode = uint8(bound(mode, 0, 4));
        uint256 bal = ghostBalance[from];
        uint256 allowed = ghostAllowance[from][spender];
        uint256 cap = allowed < bal ? allowed : bal;
        if (mode == 0) {
            amount = bound(amount, 0, cap);
        } else if (mode == 1) {
            amount = allowed == type(uint256).max ? bound(amount, 0, bal) : allowed + 1;
        } else if (mode == 2) {
            amount = bal + 1;
        } else if (mode == 3) {
            amount = bound(amount, 0, cap);
            to = address(0);
        } else {
            amount = allowed == type(uint256).max ? bal : allowed;
        }

        bytes4 expected = _expectedTransferFromError(spender, from, to, amount);

        vm.prank(spender);
        try token.transferFrom(from, to, amount) returns (bool ok) {
            assertTrue(ok, "transferFrom returned false");
            assertEq(expected, bytes4(0), "transferFrom succeeded but the ledger expected a revert");
            if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            ++ghostTransferFroms;
        } catch (bytes memory err) {
            assertTrue(expected != bytes4(0), "transferFrom reverted but the ledger expected success");
            assertEq(bytes4(err), expected, "transferFrom reverted with an unexpected error");
            ++ghostRevertedTransferFroms;
        }
    }

    /// @dev Any call shape that could mint, burn, pause or take ownership must leave the ledger untouched.
    function adminProbe(uint256 callerSeed, uint8 which) external {
        address caller = _holder(callerSeed);
        string[8] memory sigs = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "transferOwnership(address)",
            "setOwner(address)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        string memory sig = sigs[bound(which, 0, sigs.length - 1)];
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature(sig, caller, uint256(1)));
        assertFalse(ok, sig);
    }

    /// @dev ETH must never enter the token.
    function sendEth(uint256 callerSeed, uint256 amount) external {
        address caller = _holder(callerSeed);
        amount = bound(amount, 1, 1 ether);
        vm.deal(caller, amount);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: amount}("");
        assertFalse(ok, "the token accepted ETH");
    }

    // --- ledger ---

    function _expectedTransferError(address from, address to, uint256 amount) private view returns (bytes4) {
        if (to == address(0)) return LaunchToken.InvalidAddress.selector;
        if (ghostBalance[from] < amount) return LaunchToken.InsufficientBalance.selector;
        return bytes4(0);
    }

    function _expectedTransferFromError(address spender, address from, address to, uint256 amount)
        private
        view
        returns (bytes4)
    {
        uint256 allowed = ghostAllowance[from][spender];
        if (allowed != type(uint256).max && allowed < amount) return LaunchToken.InsufficientAllowance.selector;
        return _expectedTransferError(from, to, amount);
    }

    function _holder(uint256 seed) private view returns (address) {
        return holders[bound(seed, 0, holders.length - 1)];
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    LaunchTokenHandler handler;
    LaunchToken token;

    uint256 constant ACTORS = 6;

    function setUp() public {
        handler = new LaunchTokenHandler(ACTORS);
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = LaunchTokenHandler.transfer.selector;
        selectors[1] = LaunchTokenHandler.approve.selector;
        selectors[2] = LaunchTokenHandler.transferFrom.selector;
        selectors[3] = LaunchTokenHandler.adminProbe.selector;
        selectors[4] = LaunchTokenHandler.sendEth.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The fixed supply never changes and equals the sum of every holder's balance.
    function invariant_supplyIsFixedAndConserved() public view {
        assertEq(token.totalSupply(), 1e27, "supply changed");
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY(), "totalSupply != TOTAL_SUPPLY");
        uint256 sum;
        for (uint256 i; i < handler.holderCount(); ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, token.totalSupply(), "sum of balances != supply");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
    }

    /// @dev Every balance equals what the ghost ledger says the holder received minus what it sent.
    function invariant_balancesMatchLedger() public view {
        for (uint256 i; i < handler.holderCount(); ++i) {
            address h = handler.holders(i);
            assertEq(token.balanceOf(h), handler.ghostBalance(h), "balance != ledger");
            assertLe(token.balanceOf(h), token.totalSupply(), "balance exceeds supply");
        }
    }

    /// @dev Every allowance equals the ledger's: set by approve, decremented by finite transferFrom,
    /// untouched by infinite transferFrom and by any reverted call.
    function invariant_allowancesMatchLedger() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.holders(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.holders(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance != ledger");
            }
        }
    }

    /// @dev The token holds no ETH and its metadata is immutable.
    function invariant_noEtherAndFixedMetadata() public view {
        assertEq(address(token).balance, 0, "the token holds ETH");
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "The Comb");
        assertEq(token.symbol(), "COMB");
    }

    /// @dev Both the success and the failure paths must have been driven for the campaign to mean anything.
    function invariant_campaignIsNotVacuous() public view {
        uint256 total = handler.ghostTransfers() + handler.ghostRevertedTransfers() + handler.ghostTransferFroms()
            + handler.ghostRevertedTransferFroms();
        if (total >= 32) {
            assertGt(handler.ghostTransfers(), 0, "no transfer ever succeeded");
            assertGt(handler.ghostRevertedTransfers(), 0, "no transfer ever reverted");
        }
    }
}
