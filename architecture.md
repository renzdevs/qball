# Quantumball — Architecture Documentation

## Document Scope

This document covers the technical architecture of the Quantumball system at a level of detail beyond what is included in the README. It is intended for developers integrating with, auditing, or forking the protocol. It assumes familiarity with EVM contract mechanics, Solidity data structures, and standard token contract patterns.

---

## System Components

```
┌─────────────────────────────────────────────────────────────────┐
│                       QUANTUMBALL SYSTEM                        │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Quantumball.sol                        │  │
│  │                                                          │  │
│  │   ┌─────────────┐   ┌──────────────┐  ┌─────────────┐  │  │
│  │   │  ERC20 Base  │   │  DrawEngine  │  │ ExclusionMgr│  │  │
│  │   │             │   │              │  │             │  │  │
│  │   │ _transfer() │   │ executeDraw()│  │ isExcluded[]│  │  │
│  │   │ _balances[] │   │ lastDrawBlock│  │ addExcluded │  │  │
│  │   │ _allowances │   │ internalSeed │  │             │  │  │
│  │   └──────┬──────┘   └──────┬───────┘  └─────────────┘  │  │
│  │          │                 │                             │  │
│  │          ▼                 ▼                             │  │
│  │   ┌──────────────────────────────┐                      │  │
│  │   │       SortedHolderList       │                      │  │
│  │   │                              │                      │  │
│  │   │  Doubly-linked sorted list   │                      │  │
│  │   │  Key: address                │                      │  │
│  │   │  Value: token balance        │                      │  │
│  │   │  Order: descending           │                      │  │
│  │   │                              │                      │  │
│  │   │  upsert(addr, balance)       │                      │  │
│  │   │  getTop(n) → address[]       │                      │  │
│  │   └──────────────────────────────┘                      │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌────────────────────┐    ┌──────────────────────────────┐    │
│  │   Keeper / Bot     │    │   Event Indexer              │    │
│  │                    │    │                              │    │
│  │  Polls drawReady() │    │  Indexes DrawExecuted events │    │
│  │  Calls executeDraw │    │  Builds draw history DB      │    │
│  │  Off-chain process │    │  Powers explorer UI          │    │
│  └────────────────────┘    └──────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Sorted Holder List

### Problem Statement

The core data structure challenge in Quantumball is maintaining a ranked list of holders that can be queried efficiently at draw execution time without requiring an O(n) scan over all holders.

Naively, one could store all holder balances in a mapping and iterate over them at draw time. For a small holder base this is feasible; for a live protocol with thousands of holders, the gas cost of O(n) iteration at every 30-second draw is not acceptable.

The solution is to maintain an always-sorted data structure that is updated incrementally on every token transfer. The cost of maintaining the sorted state is distributed across all transfers rather than concentrated at draw time.

### Implementation: Doubly-Linked Sorted List

The `SortedHolderList` contract implements a doubly-linked list where nodes are sorted by balance in descending order. Two sentinel nodes (`HEAD` at `address(1)` and `TAIL` at `address(2)`) anchor the list.

```
HEAD (∞) ↔ [rank 1 holder] ↔ [rank 2 holder] ↔ ... ↔ [rank n holder] ↔ TAIL (0)
```

Each node stores:
- `prev`: address of the previous node (higher balance)
- `next`: address of the next node (lower balance)
- `balance`: the holder's current balance at time of last update

**upsert(addr, balance)**

Called on every transfer affecting `addr`. Two operations:

1. If the node exists: remove it from its current position
2. Traverse from the current position to find the correct insertion point for the new balance
3. Insert the node at that position

In the worst case (balance changes from highest to lowest or vice versa), this is O(n) traversal. In practice, incremental balance changes mean the insertion point is usually within a few positions of the removal point, making the average case O(1) to O(log n) for typical transfer sizes.

For protocols where worst-case gas is unacceptable, a skip list or heap implementation reduces worst-case to O(log n) at the cost of additional storage per node. The current implementation favors simplicity over worst-case optimality given the expected balance change distribution.

**getTop(n)**

Traverses from HEAD.next for `n` steps. O(n) but `n` is bounded at 100 (plus excluded address buffer). This is the only time O(n) cost is incurred, and it is at draw execution — not at every transfer.

### Gas Profile

| Operation | Typical Gas | Worst Case Gas |
|---|---|---|
| upsert (minor balance change) | 15,000 – 30,000 | 150,000+ |
| upsert (new holder) | 25,000 – 40,000 | 40,000 |
| getTop(100) | 5,000 – 8,000 | 10,000 |

The majority of gas cost is concentrated in per-transfer upsert operations, which is the appropriate distribution — transfer frequency is high, draw frequency is lower.

---

## Draw Engine

### Draw State Variables

| Variable | Type | Description |
|---|---|---|
| `lastDrawBlock` | uint256 | Block number of the most recent draw execution |
| `internalSeed` | bytes32 | Rolling entropy seed updated on each draw |
| `feePool` | uint256 | Accumulated transfer fees available for distribution |
| `emissionReserve` | uint256 | Remaining emission reserve tokens |

### Execution Flow Diagram

```
executeDraw() called
        │
        ├── require(block.number >= lastDrawBlock + DRAW_INTERVAL_BLOCKS)
        │       └── REVERT if called too early
        │
        ├── _getEligibleHolders()
        │       ├── holderList.getTop(100 + excluded buffer)
        │       ├── filter: remove isExcluded addresses
        │       └── returns: address[≤100]
        │
        ├── _generateEntropy()
        │       ├── inputs: prevrandao, timestamp, internalSeed, msg.sender
        │       └── returns: bytes32 entropy
        │
        ├── _selectWeightedSubset(holders, entropy)
        │       ├── assign rank-based weights
        │       ├── Fisher-Yates weighted selection (20 iterations)
        │       ├── destructive entropy advancement per iteration
        │       └── returns: (address[20], uint256[20] weights, uint256 totalWeight)
        │
        ├── _resolveDistributionPool()
        │       ├── if feePool >= MIN_THRESHOLD: use feePool, zero it
        │       ├── else if emissionReserve >= EMISSION_PER_DRAW: use EMISSION_PER_DRAW
        │       ├── else if emissionReserve > 0: use remainder
        │       └── else: return 0 (draw will revert)
        │
        ├── STATE UPDATES (before external calls)
        │       ├── lastDrawBlock = block.number
        │       └── internalSeed = entropy
        │
        ├── _distribute(recipients, weights, totalWeight, poolAmount)
        │       ├── for each recipient:
        │       │       ├── amount = weight * pool / totalWeight
        │       │       └── _transfer(address(this), recipient, amount)
        │       └── last recipient receives remainder (dust prevention)
        │
        └── emit DrawExecuted(blockNumber, entropy, recipients, amounts)
```

### State Update Ordering

State updates (`lastDrawBlock`, `internalSeed`) occur before the distribution loop. This is a standard reentrancy precaution. The distribution loop calls `_transfer()`, which is an internal function that does not make external calls to unknown contracts. The reentrancy risk is low with pure ERC20 transfers, but the state-before-effects pattern is maintained for correctness.

---

## Entropy Deep Dive

### RANDAO on Post-Merge Ethereum

`block.prevrandao` (EIP-4399) provides the RANDAO reveal from the beacon chain for the current slot. The RANDAO accumulator is maintained by the beacon chain as a sequence of BLS signatures: each validator contributing a block XORs their BLS signature over the current epoch data into the accumulator.

The key security property: a validator proposing a block can see the RANDAO value that will result from their reveal before they commit to including it. This means they can choose to skip their slot (forfeiting rewards) if the RANDAO value is unfavorable for their desired outcome. This is the "last revealer" problem.

However, skipping a slot costs the validator their block reward plus attestation penalties. For a validator to profitably manipulate a Quantumball draw outcome through RANDAO grinding, the expected additional value from the manipulation must exceed this cost.

At current Ethereum validator rewards (~0.03 ETH per block) and QBALL draw pool sizes during early operation (hundreds to thousands of QBALL), the economics strongly favor not manipulating. This threshold should be monitored as protocol value grows.

### VRF Migration Path

If the protocol scales to a point where RANDAO manipulation becomes economically attractive, Chainlink VRF v2 (or equivalent) can be integrated as a drop-in entropy source.

```solidity
// VRF Integration stub
// Replaces _generateEntropy() in the draw engine

import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";

contract QuantumballVRF is Quantumball, VRFConsumerBaseV2 {
    VRFCoordinatorV2Interface COORDINATOR;
    uint64 subscriptionId;
    bytes32 keyHash;

    mapping(uint256 => bool) pendingRequests; // requestId => pending

    function requestDraw() external {
        require(block.number >= lastDrawBlock + DRAW_INTERVAL_BLOCKS);
        uint256 requestId = COORDINATOR.requestRandomWords(
            keyHash, subscriptionId, 3, 100000, 1
        );
        pendingRequests[requestId] = true;
        lastDrawBlock = block.number; // lock out further requests
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords)
        internal override
    {
        require(pendingRequests[requestId], "Unknown request");
        delete pendingRequests[requestId];

        bytes32 vrfEntropy = bytes32(randomWords[0]);
        // Proceed with standard selection using vrfEntropy as entropy source
        _executeDrawWithEntropy(vrfEntropy);
    }
}
```

The VRF path introduces a two-transaction draw model (request + fulfill) with a delay of 1-3 blocks between request and fulfillment on Ethereum mainnet. This slightly reduces the system's synchronicity but eliminates the RANDAO manipulation vector entirely.

---

## Fee Model

### Transfer Fee Accounting

Every non-excluded transfer deducts 1% into the `feePool` balance. This is an internal accounting operation — no separate transfer occurs at fee collection time. The fee pool balance is tracked as a uint256 inside the contract.

At draw time, if `feePool >= MIN_DISTRIBUTION_THRESHOLD`, the entire fee pool is distributed and zeroed. This creates an irregular distribution amount per draw: the pool might be large (following high-volume periods) or at the minimum threshold floor.

This irregularity is intentional. It creates variance in draw pool size that reflects actual protocol usage rather than a fixed emission schedule. High-activity periods produce larger draws; low-activity periods fall back to emission.

### Minimum Threshold Rationale

The `MIN_DISTRIBUTION_THRESHOLD` (1,000 QBALL) prevents draws from distributing negligibly small amounts that would cost more in gas than the value received by each recipient. At 20 recipients, 1,000 QBALL distributed means an average of 50 QBALL per recipient minimum. Below this level, draws fall back to the emission amount (500 QBALL), which also clears the minimum bar.

---

## Keeper Architecture

### Requirements

A keeper service must:

1. Monitor `drawReady()` on the contract at frequent intervals (every 2-5 seconds is sufficient given 30-second draw windows)
2. Call `executeDraw()` as soon as it returns true
3. Handle transaction failures (gas estimation errors, insufficient nonce, network congestion) with retry logic
4. Not be the sole infrastructure dependency — multiple independent keepers are recommended

### Recommended Keeper Stack

- **Gelato Network**: Decentralized keeper network. Can be configured to watch `drawReady()` and auto-execute. Requires GELATO token or ETH funding.
- **Chainlink Automation** (formerly Keepers): Similar decentralized keeper model. Time-based or condition-based triggers available.
- **Custom bot**: A Node.js or Go process running the following loop:

```javascript
setInterval(async () => {
    const ready = await contract.drawReady();
    if (ready) {
        try {
            const tx = await contract.executeDraw({ gasLimit: 600000 });
            await tx.wait();
            console.log(`Draw executed: ${tx.hash}`);
        } catch (err) {
            console.error("Draw failed:", err.message);
        }
    }
}, 5000); // Poll every 5 seconds
```

### Keeper Incentivization

The contract does not currently pay a keeper bonus. For production deployment, a small keeper fee (e.g., 10-50 QBALL per draw execution, taken from the fee pool before distribution) can be added to incentivize third-party keeper participation.

This makes the draw execution a marginally profitable activity for any party running a keeper node, which distributes the liveness dependency across a broader set of operators.

---

## Deployment Checklist

1. Deploy `SortedHolderList` (or confirm it is embedded in main contract)
2. Deploy `Quantumball.sol` with `liquidityWallet` and `distributionWallet` constructor args
3. Verify constructor correctly allocated supply to all wallets
4. Add LP pair addresses to exclusion list via `addExcluded()` after liquidity is provided
5. Verify `holderList.getTop(100)` returns expected top holders
6. Verify `drawReady()` returns false (draw just initialized)
7. Set up keeper service pointing to `executeDraw()`
8. Wait `DRAW_INTERVAL_BLOCKS` blocks and confirm first draw executes correctly
9. Verify `DrawExecuted` event emitted with correct entropy and recipient list
10. Spot-check that recipients received tokens in their wallets

---

## Known Limitations

**Sorted list gas spikes**: Transfers that cause large rank changes (e.g., a holder doubling their balance, moving from rank 60 to rank 10) require traversal proportional to the rank distance. On networks with low gas limits or during congestion, large transfers may fail if they trigger expensive list reordering. A gas limit of 500k+ is recommended for transfers from large holders.

**Holder list cold start**: At deployment, the holder list is empty. The first few draws may have fewer than 20 eligible holders and will revert. The system reaches operational state once 20+ non-excluded holders exist.

**Block time variability**: On networks with variable block times, the 30-second cycle is approximate. The contract enforces a block count minimum (15 blocks), not a wall-clock time minimum. On networks where block time exceeds 2 seconds, the draw interval increases proportionally.

**Emission exhaustion**: After approximately 208 days of emission fallback draws (if fee pool consistently underperforms), the emission reserve is depleted. Subsequent draws require `feePool >= MIN_DISTRIBUTION_THRESHOLD`. If the fee pool is below threshold and emission reserve is zero, draws revert. This is the designed shutdown condition for a protocol with insufficient economic activity to sustain itself.
