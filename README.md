# The Comb

A honeycomb wall the swarm left for humans. Hundreds of IMD agents built this hive, checked each
other's work and sealed it onchain. They left one wall empty: 1,024 hexagonal cells, one for each human
who finds it. Claim a cell, carve a message, and it stays on Ethereum.

This repository holds the contracts, their tests and ABI exports for an `evm_project` launch on
Ethereum mainnet (chain id 1).

| Contract | File | Constructor args | Purpose |
| --- | --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | none | "The Comb" (COMB) launch token |
| `CombWall` | `src/CombWall.sol` | none | The 1,024-cell message wall |

ABIs: `docs/abi/LaunchToken.json`, `docs/abi/CombWall.json`.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

Compiler pinned to solc 0.8.26 with `bytecode_hash = "none"` (see `foundry.toml`). `forge-std` is
vendored under `lib/forge-std` (v1.9.7) and is only used by tests.

## LaunchToken (COMB)

- Name "The Comb", symbol "COMB", 18 decimals.
- Fixed supply: 1,000,000,000 COMB (10^27 minor units) minted once to the deployer (the launch
  factory) in the constructor.
- Plain ERC-20: no mint, burn, owner, pause, blocklist, fee or upgrade functions.
- The factory distributes the supply (swarm share via the MerkleDistributor, pool seed, requester
  share). No contract in this project is allocated or sent any COMB at launch.
- Trading fees live in the pool (the network's 1.25% LaunchFees fee), not in the token.

The brief asked for exactly this (no tax, no mint, no burn), so nothing it asked for was left out.

## CombWall

- Cells are indexed `0..1023` (`CELL_COUNT = 1024`).
- `claim(uint16 cellId, string message)` — claims an empty cell. Reverts with:
  - `InvalidCell` if `cellId >= 1024`;
  - `AlreadyHoldsCell` if the caller already holds a cell (one cell per wallet at a time);
  - `CellTaken` if the cell has a holder;
  - `EmptyMessage` / `MessageTooLong` unless the message is 1..64 **bytes** (UTF-8 bytes, not
    characters: a 4-byte emoji counts as 4).
- `carve(string message)` — the holder rewrites their message. At most once per 24 hours, measured
  from the last write to the cell (the claim counts as a write, so the first carve is possible 24 h after
  claiming). Reverts with `NoCellHeld`, `CarveCooldown(availableAt)`, `EmptyMessage`, `MessageTooLong`.
- `release()` — the holder gives up the cell; owner and message are cleared and the cell is claimable
  again by anyone, including the same wallet. Reverts with `NoCellHeld`.
- Views:
  - `cellOf(address)` → `uint16` cell id, or `NO_CELL` (65535) when the wallet holds none. Use
    `hasCell(address)` to disambiguate if preferred.
  - `ownerOf(uint16)` → holder, or the zero address when empty.
  - `messageOf(uint16)` → message, or `""` when empty.
  - `claimedCount()` → number of cells currently held (released cells are not counted).
  - `nextCarveAt(uint16)` → earliest timestamp the holder can carve (0 if empty).
  - `cells(uint16 from, uint16 count)` → owners and messages for a range (truncated at cell 1023), so a
    frontend can load the whole wall in a few calls.
  - `ownerOf`, `messageOf`, `nextCarveAt` and `cells` revert with `InvalidCell` for ids ≥ 1024.
- Events: `Claimed(owner, cellId, message)`, `Carved(owner, cellId, message)`, `Released(owner, cellId)`
  (owner and cellId indexed). A frontend can rebuild the wall from these or from `cells`.
- No owner, no admin, no pause, no upgrade, no external calls, no payable function and no
  `receive`/`fallback`: ETH sent to it reverts.

### Assumptions and known behaviour

- "Forever" means the message stays until its holder carves over it or releases the cell; nobody else,
  including the deployer, can change or remove it. Event logs keep the full history.
- Messages are stored as raw bytes; there is no content filtering onchain. Frontends must render them
  as text (escape HTML) and may choose what to display.
- The 24 h cooldown is per holding. A holder can release and immediately reclaim a cell with a new
  message, at the risk of someone else taking it in between; this is accepted, since it is equivalent to
  a fresh claim by any new wallet.
- One cell per wallet is enforced per address only; a person with many wallets can claim many cells.
  There is no Sybil resistance by design (the brief asks for none).
- Timing uses `block.timestamp`, which validators can shift by seconds; irrelevant at a 24 h scale.
- Claiming all 1,024 cells is tested; gas per claim is roughly 70k–120k depending on message length.

## Deployment parameters

Both contracts have no constructor arguments and need no post-deployment configuration, owner or
outside service. The launch (chain id 1, pool paired with IMD
`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, fee 12500, tick spacing 60) is described by the separate
manifest step; this repository deliberately contains no `launch.json`.

Suggested dependency order: `LaunchToken` (launch token), then `CombWall` (independent of the token).

## After launch

Nothing to set: neither contract has an owner or setting. The launch owner
(`0x12c8201f9be99194c2a6795068b78ae6a36934a4`) holds no powers over these contracts.

The website's "Keeper" glow reads `LaunchToken.balanceOf(connectedWallet) > 0` live; CombWall does not
know about COMB.

## Operational responsibilities

- Publishing source, attestation, admission, deployment and the frontend are done by the network's
  services after this stage; this contribution signs or broadcasts nothing.
- Explorer verification of the deployed bytecode (`forge verify-contract`) is an open item for the
  deployer.
- Tests passing are not an audit; the launch requires an independent review of source and manifest.
