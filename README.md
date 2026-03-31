# QUANTUMBALL

<img src="qballp.png" width="200"/>

**QBALL** — A continuous, high-frequency probabilistic distribution system built on deterministic on-chain entropy.

---

## TABLE OF CONTENTS

1. [Introduction](#introduction)
2. [Core Concept](#core-concept)
3. [System Overview](#system-overview)
4. [The Draw](#the-draw)
5. [Eligibility](#eligibility)
6. [Entropy](#entropy)
7. [Distribution Model](#distribution-model)
8. [Pseudocode](#pseudocode)
9. [System Properties](#system-properties)
10. [What This Is](#what-this-is)
11. [What This Is Not](#what-this-is-not)
12. [Design Philosophy](#design-philosophy)
13. [Contract Architecture](#contract-architecture)
14. [Security Considerations](#security-considerations)
15. [Deployment Parameters](#deployment-parameters)
16. [Conclusion](#conclusion)

---

## INTRODUCTION

Quantumball is a continuous distribution system. It runs on a 30-second cycle, every cycle. It does not pause, queue, or wait for user input. There is no interface to interact with, no claim button to press, no staking contract to approve. Holding QBALL tokens at the moment of execution is the only requirement for eligibility.

At the protocol level, Quantumball maintains a live view of the top 100 QBALL holders at each execution window. When a draw executes, it selects recipients from that set using a deterministic entropy function derived from block data. It then distributes tokens from the fee pool or emission reserve directly to those recipients.

The system does not stop. It does not require governance to keep running. It does not depend on external keepers beyond the initial bootstrapping layer. Once deployed and funded, it cycles.

This document describes every component of the system: how draws work, how entropy is sourced, how recipients are selected, how tokens are distributed, and why each design decision was made the way it was.

---

## CORE CONCEPT

### Superposition

In quantum mechanics, a particle exists in superposition — it holds all possible states simultaneously until the act of observation forces it into one. Quantumball borrows this framing as a precise analogy for the state of the system between draw executions.

Between draws, every address in the top 100 is simultaneously a potential recipient. The system has not decided who receives. No single outcome is fixed. The entire eligible set is, in a meaningful sense, in superposition: all outcomes are live, none are resolved.

This is not a metaphor applied loosely. It is a structural description of the contract state. Before the block closes on a draw execution, the holder set is determined but the winner set is not. Both the entropy inputs and the selection function output are unknowable until the block is sealed. The outcome is genuinely undetermined from any pre-execution vantage point.

### Collapse

At execution, the entropy function is called. Block data is consumed. The seed is updated. The selection function runs. The superposition collapses into a fixed outcome: a specific set of recipients with specific distribution weights. That outcome is deterministic, recorded on-chain, and fully verifiable after the fact.

This is called the collapse. It is the moment the system resolves from all-possible to one-actual.

The collapse is not random in the informal sense. It is deterministic. Given the same inputs, it always produces the same outputs. The unpredictability comes entirely from the unknowability of future block data, which is computationally infeasible to predict before the block is mined.

### High-Frequency Execution

The draw cycle is 30 seconds. This is aggressive. It means the system executes approximately 2,880 draws per day, 86,400 per month. Each draw is a complete execution of the entropy function, the selection algorithm, and the distribution logic.

The high frequency is not cosmetic. It is a functional design choice. It means:

- Holder ranks change between draws, creating live, continuous competition for top-100 positions
- The fee pool turns over rapidly, so no large lump-sum accumulations sit idle
- The system produces a constant stream of on-chain events, making it inspectable and auditable in near-real-time
- Any attempt to game the entropy requires sustained, expensive block-level manipulation across a high volume of blocks — not a single targeted attack

Frequency is a security property as much as it is a UX property.

---

## SYSTEM OVERVIEW

```
                    ┌──────────────────────────────┐
                    │         TOKEN HOLDERS         │
                    │  Passive. No action required. │
                    └──────────────┬───────────────┘
                                   │
                                   │  Live balance query
                                   │  at block of execution
                                   ▼
                    ┌──────────────────────────────┐
                    │         TOP 100 SET           │
                    │  Ranked by current balance.   │
                    │  No historical weight.        │
                    │  No stake. No lock.           │
                    └──────────────┬───────────────┘
                                   │
                                   │  Eligible set enters
                                   │  superposition state
                                   ▼
                    ┌──────────────────────────────┐
                    │         SUPERPOSITION         │
                    │  All 100 are potential        │
                    │  recipients simultaneously.   │
                    │  Outcome is undetermined.     │
                    └──────────────┬───────────────┘
                                   │
                                   │  Entropy function called
                                   │  Block hash + timestamp
                                   │  + internal rolling seed
                                   ▼
                    ┌──────────────────────────────┐
                    │           COLLAPSE            │
                    │  Deterministic selection.     │
                    │  Fixed output from fixed      │
                    │  entropy inputs.              │
                    └──────────────┬───────────────┘
                                   │
                                   │  Push distribution
                                   │  No claiming required
                                   ▼
                    ┌──────────────────────────────┐
                    │         DISTRIBUTION          │
                    │  Tokens sent directly.        │
                    │  From fee pool or emission.   │
                    │  Cycle resets. 30s begins.    │
                    └──────────────────────────────┘
```

The cycle above repeats without interruption. Each draw conclusion immediately initializes the next draw window. The system is always in one of two states: accumulating (between draws) or executing (at the draw block).

---

## THE DRAW

The draw is the atomic unit of the Quantumball system. Everything else — the entropy model, the distribution pool, the eligibility rules — exists to support a single draw execution.

### Trigger

Draws are triggered at 30-second intervals measured in block time. The contract stores a `lastDrawBlock` value. Any account (or keeper) may call `executeDraw()` once the required number of blocks have elapsed. The contract verifies this condition internally and reverts if called too early.

The draw is permissionless in its trigger. Anyone can execute it. The outcome does not change based on who calls it.

### Execution Steps

When `executeDraw()` is called, the following operations occur in sequence within a single transaction:

**Step 1 — Holder Set Resolution**

The contract queries the current top 100 QBALL holders by balance. This is a live, point-in-time lookup. It reflects the actual token distribution at the block of execution. Any holder who sold their position one block prior is excluded. Any holder who accumulated into the top 100 one block prior is included.

There is no snapshot. There is no grace period. The state is current or it is not considered.

**Step 2 — Entropy Generation**

The entropy function is called. It consumes:

- `block.prevrandao` (or `blockhash(block.number - 1)` on chains without RANDAO)
- `block.timestamp`
- `internalSeed` (a rolling uint256 updated on every draw)

These three values are hashed together to produce a 256-bit entropy value. This value is used as the seed for all selection operations in the current draw.

The internal seed is updated at the end of every draw, making each draw's entropy partially dependent on all prior draws. This prevents reuse attacks and ensures the seed state cannot be predicted from public information alone without knowing the entire prior chain of draw outputs.

**Step 3 — Winner Selection**

The entropy value is used to select recipients from the top 100 set. The selection model is described in detail in the Distribution Model section. At a high level: the entropy is consumed iteratively to produce a weighted subset of the eligible set. Each selected address has a determined allocation weight.

**Step 4 — Distribution**

Tokens are distributed immediately, in the same transaction. There is no queuing, no pending balance, no claim step. The `distribute()` function iterates over the selected recipients and calls `_transfer()` for each, pulling from the distribution pool. By the time the transaction is confirmed, recipients have already received their tokens.

**Step 5 — State Update**

`lastDrawBlock` is updated. `internalSeed` is updated. Event logs are emitted with the full draw result: block number, entropy hash, recipient list, and individual amounts. The next draw window opens.

Total gas cost per draw scales linearly with recipient count. At 20 recipients per draw (the default subset size), this is within standard block gas limits on all target chains.

---

## ELIGIBILITY

### Who Is Eligible

Eligibility is defined at the moment of draw execution:

- The address must hold QBALL tokens
- The address must be ranked within the top 100 holders by current balance
- The address must not be a blacklisted address (contract owner, liquidity pool, burn address, team reserves)

That is the complete eligibility specification.

### What Does Not Matter

The following factors have zero weight in eligibility determination:

- How long the address has held QBALL
- Whether the address held QBALL during prior draws
- Whether the address participated in any previous interaction with the contract
- The address's historical balance peak or average
- Whether the address has ever received a prior distribution

Each draw evaluates the holder set entirely from scratch. A wallet that bought QBALL one block before the draw executes is fully eligible. A wallet that held QBALL for six months but sold the day before is fully ineligible.

### The Top 100 Constraint

The top 100 constraint exists for gas and attack surface reasons, not as a value judgment. Iterating over an unbounded holder set is not feasible within block gas limits on a 30-second cycle. 100 holders represents a practical upper bound that keeps gas costs manageable while covering a meaningful portion of the active token economy.

As the holder base grows, the competition for the top 100 becomes more dynamic. Early in the protocol's life, entrance into the top 100 requires a relatively small holding. As the token distributes, the threshold rises. This creates a natural, continuous pressure on the distribution of holdings.

### Excluded Addresses

The following address categories are permanently excluded from eligibility regardless of balance:

- The contract deployer address
- Verified liquidity pool addresses (Uniswap v2/v3 pair contracts)
- The zero address
- The token contract itself
- Any address explicitly added to the exclusion list via governance

The exclusion list is onchain and publicly inspectable. Its contents cannot be changed without an on-chain transaction. Any addition to the exclusion list is a permanent, auditable event.

---

## ENTROPY

### The Problem With On-Chain Randomness

True randomness is not available on a deterministic blockchain. Any value that can be computed by the contract can, in principle, be computed by a miner or validator before committing a block. This is the core tension in on-chain entropy design: the more predictable the inputs, the more gameable the outcome.

Quantumball does not claim to produce cryptographically unpredictable randomness. It claims to produce deterministic outputs from inputs that are practically infeasible to manipulate at the cost structure the system operates in.

### Entropy Inputs

```
entropy = keccak256(
    abi.encodePacked(
        block.prevrandao,       // EIP-4399 beacon chain randomness (post-Merge)
        block.timestamp,         // Block timestamp in seconds
        internalSeed,            // Rolling internal state updated per draw
        msg.sender               // Caller address at execution time
    )
)
```

**block.prevrandao**

Post-Merge Ethereum provides `block.prevrandao` (formerly `block.difficulty`), which is derived from the beacon chain's RANDAO reveal. This value is determined by the current validator's BLS signature over the current epoch and slot data. It cannot be known in advance by any party, including the block proposer, until the slot is reached. The beacon chain's RANDAO design ensures that a single validator's ability to manipulate this value is limited: they can choose to skip a slot (sacrificing rewards), but they cannot choose the value they would reveal.

**block.timestamp**

The block timestamp adds a time-domain component. While miners/validators have limited ability to shift this value (within ~12 seconds on Ethereum mainnet), using it in combination with other inputs reduces the feasibility of grinding the entropy output to a desired value.

**internalSeed**

The internal seed is a contract-level uint256 that is updated at every draw using the prior draw's entropy output. This creates a dependency chain: the entropy for draw N+1 depends on the entropy output of draw N, which depended on draw N-1, and so on back to contract deployment. Any attempt to manipulate entropy at draw N requires having manipulated all prior draws, which is computationally and economically prohibitive across thousands of daily executions.

**msg.sender**

The caller address at draw execution time is included as a minor additional input. Since anyone can call the draw, this is not a security primitive on its own. Its function is to ensure that even if two draws occur in the same block (which the contract prevents, but for defensive completeness), the outputs would differ.

### Entropy Consumption

The 256-bit entropy value is consumed through a Fisher-Yates style shuffle adapted for subset selection:

```
seed = entropy
for i in range(SUBSET_SIZE):
    index = seed % (100 - i)
    swap(holders[i], holders[index])
    seed = keccak256(seed)
```

Each iteration consumes the seed destructively, ensuring that positional correlation between selected recipients is minimized. The re-hashing of the seed at each step means the full 256-bit space is explored across the selection loop rather than using sequential windows of a single hash output.

### What This Achieves

The entropy model achieves the following properties:

- **Determinism**: Given the same block state and internal seed, the draw always produces the same output
- **Verifiability**: All inputs are publicly available on-chain after the block is sealed
- **Manipulation resistance**: Producing a specific desired outcome requires grinding multiple entropy components simultaneously, including the internal seed which requires control of all prior draws
- **Non-repeatability**: The internal seed ensures no two draws can share an entropy state even if block conditions are similar

What it does not achieve: cryptographic unguessability against a validator who is also the largest QBALL holder and is willing to sacrifice block rewards. The system's defense against this is economic: the cost of consistent entropy manipulation (repeated missed slots, coordination costs) must exceed the value extractable from draw manipulation. At typical QBALL distribution pool sizes, this margin is expected to be wide. If the protocol scales to a point where this margin narrows, migration to a VRF-based entropy source (Chainlink VRF, Pyth Entropy) should be evaluated.

---

## DISTRIBUTION MODEL

### The Choice: Weighted Subset Selection

After evaluating two candidate models — equal distribution to all 100 holders, and weighted random subset selection — the system implements **weighted random subset selection**.

The default subset size is 20 recipients per draw (20% of the eligible set).

### Why Not Equal Distribution To All 100

Equal distribution to all 100 eligible holders per draw is mechanically simple and maximally inclusive. Its problems are practical and structural:

**Gas cost**: Distributing to 100 addresses in a single transaction on a 30-second cycle creates predictable, significant gas overhead per block. On high-throughput chains this is manageable; on Ethereum mainnet it is not. Subset selection allows the system to operate within block gas limits across a wider range of deployment targets.

**Distribution dynamics**: If every top-100 holder receives every draw, the distribution is a flat, predictable tax on the emission/fee pool spread across a fixed set. It creates no variation in outcome per draw and no dynamic incentive to compete for top-100 positioning beyond the binary in/out threshold.

**Entropy utilization**: Running the full entropy function to select 100 of 100 is wasteful. Entropy is only meaningful when it gates access to a subset. Selecting all produces a deterministic outcome regardless of the entropy value.

### Why Weighted Subset

Selecting a random subset of 20 from the top 100 on each draw creates a fundamentally different incentive structure:

- Any given top-100 holder has a 20% probability of receiving any given draw
- Over 144 draws per hour, expected value across holders converges toward equity, but variance within any short window is meaningful
- Higher-ranked holders (larger balances) receive higher weights in the selection, so their per-draw probability is above 20% and lower-ranked holders are below — but no one in the top 100 is excluded entirely
- The subset changes every draw, creating a dynamic, continuously cycling output rather than a static recurring list

### Weighting Function

Recipient weights are proportional to balance rank, not balance magnitude. The top holder receives weight `100`, the second holder receives weight `99`, and so on down to the 100th holder, who receives weight `1`.

Using rank rather than raw balance prevents a single whale from monopolizing distributions through token concentration. The weight difference between rank 1 and rank 100 is a factor of 100, not a factor of (whale balance / minimum balance), which could be arbitrarily large.

The selection probability for holder at rank `r` (1-indexed, 1 = top holder):

```
weight(r) = 101 - r

total_weight = sum(weight(r) for r in 1..100) = 5050

P(selected | rank r) ≈ weight(r) / total_weight * SUBSET_SIZE
                     = (101 - r) / 5050 * 20
```

For rank 1:   P ≈ 100/5050 * 20 ≈ 39.6%
For rank 50:  P ≈ 51/5050 * 20  ≈ 20.2%
For rank 100: P ≈ 1/5050 * 20   ≈ 0.4%

These are per-draw probabilities. Over 2,880 daily draws:

Expected draws received per day:
- Rank 1:   ≈ 1,140
- Rank 50:  ≈ 581
- Rank 100: ≈ 11

No holder is excluded from expected value. All holders in the top 100 should expect meaningful distributions over any multi-day window.

### Distribution Amounts

Once the 20 recipients are selected, the per-recipient amount is determined by their proportional weight within the selected subset:

```
recipient_share(i) = weight(rank_i) / sum(weight for all selected recipients)
                   * total_draw_pool
```

This means that even within a given draw, a higher-ranked recipient receives a larger share than a lower-ranked co-recipient. The distribution is neither flat-equal nor winner-take-all; it is continuously graduated within the selected subset.

### Distribution Pool

The tokens distributed per draw come from two potential sources, in priority order:

1. **Fee accumulation pool**: QBALL implements a transfer fee (default 1% on all transfers). These fees accumulate in a dedicated pool address. The draw distributes the entire accumulated pool per execution if above a minimum threshold. This creates a self-sustaining distribution model: more transfer activity equals larger draw pools, which increases the incentive to hold for the draw, which increases transfer activity.

2. **Emission reserve**: A fixed portion of the initial token supply is allocated to a time-released emission reserve. If the fee pool is below the minimum threshold at draw time, the draw distributes a fixed emission amount from the reserve instead. The reserve is designed to ensure the system produces distributions even during low-activity windows.

The total distributed per draw is bounded above by the pool balance and below by the minimum threshold floor (if emission fallback is active).

---

## PSEUDOCODE

The following pseudocode describes the complete draw execution flow. This maps directly to the Solidity implementation in `/contracts/Quantumball.sol`.

```javascript
// -----------------------------------------------
// CONSTANTS
// -----------------------------------------------

ELIGIBLE_SET_SIZE = 100
SUBSET_SIZE = 20
DRAW_INTERVAL_BLOCKS = 15      // ~30 seconds at 2s/block
MIN_DISTRIBUTION_THRESHOLD = 1000 * 10^18  // 1000 QBALL

// -----------------------------------------------
// STATE
// -----------------------------------------------

lastDrawBlock = 0
internalSeed = deploymentHash
excludedAddresses = [deployer, lpPairs, zeroAddress, contractAddress]
feePool = 0
emissionReserve = EMISSION_ALLOCATION

// -----------------------------------------------
// ENTRY POINT
// -----------------------------------------------

function executeDraw() {
    require(block.number >= lastDrawBlock + DRAW_INTERVAL_BLOCKS, "Draw not ready")

    holders = getTop100Holders()
    entropy = generateEntropy()
    recipients = selectWeightedSubset(holders, entropy)
    poolAmount = resolveDistributionPool()
    distribute(recipients, poolAmount)

    internalSeed = entropy
    lastDrawBlock = block.number

    emit DrawExecuted(block.number, entropy, recipients)
}

// -----------------------------------------------
// HOLDER SET RESOLUTION
// -----------------------------------------------

function getTop100Holders() returns address[] {
    // Implementation note: the contract maintains an ordered
    // balance-sorted address list updated on every transfer.
    // This avoids O(n) iteration at draw time.
    // See: _updateHolderRanking() called in _transfer()

    candidates = holderRankList.getTop(ELIGIBLE_SET_SIZE)

    filtered = []
    for addr in candidates {
        if addr not in excludedAddresses {
            filtered.append(addr)
        }
    }

    require(filtered.length >= SUBSET_SIZE, "Insufficient eligible holders")
    return filtered
}

// -----------------------------------------------
// ENTROPY GENERATION
// -----------------------------------------------

function generateEntropy() returns bytes32 {
    return keccak256(
        abi.encodePacked(
            block.prevrandao,
            block.timestamp,
            internalSeed,
            msg.sender
        )
    )
}

// -----------------------------------------------
// WEIGHTED SUBSET SELECTION
// -----------------------------------------------

function selectWeightedSubset(address[] holders, bytes32 entropy) returns Recipient[] {
    // Assign rank-based weights
    weights = []
    for i in range(holders.length) {
        rank = i + 1
        weights[i] = ELIGIBLE_SET_SIZE + 1 - rank  // top holder = 100, last = 1
    }

    // Fisher-Yates weighted selection
    selected = []
    seed = entropy

    for i in range(SUBSET_SIZE) {
        totalWeight = sum(weights[i..])
        target = uint256(seed) % totalWeight
        
        cumulative = 0
        for j in range(i, holders.length) {
            cumulative += weights[j]
            if cumulative > target {
                selected.append({
                    address: holders[j],
                    weight: weights[j]
                })
                swap(holders[i], holders[j])
                swap(weights[i], weights[j])
                break
            }
        }

        seed = keccak256(seed)  // consume entropy destructively
    }

    return selected
}

// -----------------------------------------------
// POOL RESOLUTION
// -----------------------------------------------

function resolveDistributionPool() returns uint256 {
    if feePool >= MIN_DISTRIBUTION_THRESHOLD {
        amount = feePool
        feePool = 0
        return amount
    }

    if emissionReserve > 0 {
        amount = min(EMISSION_PER_DRAW, emissionReserve)
        emissionReserve -= amount
        return amount
    }

    revert("Distribution pool empty")
}

// -----------------------------------------------
// DISTRIBUTION
// -----------------------------------------------

function distribute(Recipient[] recipients, uint256 totalAmount) {
    totalWeight = sum(r.weight for r in recipients)

    for r in recipients {
        amount = r.weight * totalAmount / totalWeight
        _transfer(distributionPool, r.address, amount)
        emit Distributed(r.address, amount)
    }
}

// -----------------------------------------------
// TRANSFER HOOK (called on every token transfer)
// -----------------------------------------------

function _transfer(address from, address to, uint256 amount) {
    fee = amount * TRANSFER_FEE_BPS / 10000
    net = amount - fee

    feePool += fee
    balances[from] -= amount
    balances[to] += net

    _updateHolderRanking(from)
    _updateHolderRanking(to)
}

// -----------------------------------------------
// RANKING MAINTENANCE
// -----------------------------------------------

function _updateHolderRanking(address addr) {
    // Maintains a sorted linked list of holders by balance.
    // O(log n) insertion/deletion using skip list or
    // heap structure. Updated on every transfer to keep
    // getTop100Holders() O(1) at draw time.

    if balances[addr] == 0 {
        holderRankList.remove(addr)
    } else {
        holderRankList.upsert(addr, balances[addr])
    }
}
```

---

## SYSTEM PROPERTIES

### Deterministic

Given a specific block state (blockhash, timestamp, prevrandao) and a specific internal seed, `executeDraw()` always produces the same output. There is no non-determinism in the contract. The unpredictability of outcomes is a function of the unpredictability of future block data, not of any stochastic element in the contract itself.

This is a meaningful property because it means the contract can be audited in full. Every draw that has ever executed can be re-derived offline from public on-chain data. There are no hidden execution paths, no server-side components, no off-chain randomness commitments.

### Inspectable

Every draw emits a `DrawExecuted` event containing:

- Block number
- The full entropy hash (32 bytes)
- The full recipient list (up to 20 addresses)
- Per-recipient distribution amounts

These events are queryable from any standard Ethereum node or block explorer. A complete distribution history is always available. Any holder can verify whether they received a distribution and trace the exact entropy path that led to that outcome.

### Continuous

The system does not have an on/off state in normal operation. Once deployed, it runs until the distribution pool is exhausted. The fee pool is self-replenishing as long as tokens are in circulation and transferring. The emission reserve provides a floor. The system is designed to produce distributions indefinitely given ongoing token activity.

### No User Interaction Required

Recipients do not need to:

- Call any function to claim
- Approve any contract
- Sign any transaction
- Interact with any interface

Distributions arrive in recipient wallets automatically as part of the draw transaction. The system is push-based, not pull-based. This is not a UX convenience — it is a structural property. A pull-based system requires user activity to realize distributions. A push-based system distributes regardless of whether recipients are active.

### Gas Model

Each draw execution costs approximately:

| Operation | Estimated Gas |
|---|---|
| Top 100 query | ~5,000 (O(1) from sorted list) |
| Entropy generation | ~3,000 |
| Subset selection loop (20 iterations) | ~40,000 |
| Distribution transfers (20 transfers) | ~420,000 |
| State updates | ~25,000 |
| **Total** | **~493,000** |

At 2,880 draws per day, total daily gas consumption is approximately 1.42 billion gas units. On Ethereum mainnet at 30 gwei base fee this is roughly 42.6 ETH/day — not viable for L1. Quantumball is designed for deployment on L2 networks (Arbitrum, Base, Optimism) or high-throughput L1s (Solana via equivalent architecture, Avalanche C-chain) where 30-second, 500k-gas transactions are economically feasible.

On Arbitrum at typical L2 gas prices (0.01-0.1 gwei effective), daily draw execution costs are on the order of $0.05-$0.50 total. This is well within the range of what the fee pool can sustain.

---

## WHAT THIS IS

Quantumball is a continuous distribution engine. It is an experiment in applying probabilistic selection to token distribution in a way that requires no user interaction beyond holding.

It is an attempt to build a system where the act of holding a token has intrinsic, ongoing economic weight — not because the token accrues yield through DeFi mechanics, not because it is staked in a contract that pays APR, but because the protocol itself continuously redistributes value among holders on a cycle that never stops.

It is also an experiment in transparency. Every parameter — subset size, weight function, entropy inputs, fee rate, draw interval — is explicit, on-chain, and auditable. There are no hidden pools, no team withdrawal mechanisms, no distribution that bypasses the draw system. The contract does what it says it does, and what it says it does is fully documented here and in the source code.

The quantum narrative is not decoration. Superposition and collapse are precise descriptions of the contract's execution states. The language was chosen because it fits, not because it sounds interesting.

---

## WHAT THIS IS NOT

**Not gambling.** The system does not accept wagers. It does not return multiples of a bet. It does not have a house. It does not have an expected-value-negative entry mechanism. Holders do not risk their holdings on the outcome of a draw. The draw does not redistribute holdings between holders. It distributes from a separate pool — fees and emissions — to holders. Every draw is net-positive or neutral for every eligible participant.

**Not random in the traditional sense.** The system does not use a random number generator. It does not call an oracle. It does not produce outputs that are unpredictable in principle, only in practice. The entropy is deterministic. It is sourced from public blockchain data. Any party with full knowledge of all inputs could compute the output before the block is sealed — but obtaining that knowledge in advance is computationally infeasible.

**Not a lottery.** A lottery has discrete entry events, a defined pool accumulation period, and a single winner or fixed small winner set per round. Quantumball has no entry events, accumulates continuously, selects a new set every 30 seconds, and distributes to that set immediately. The mechanics and the economic structure are different at every level.

**Not hidden logic.** The selection algorithm is fully described in this document and fully implemented in the published contract source. The entropy function is documented. The weight function is documented. The exclusion list is on-chain. There are no privileged execution paths that alter the draw outcome.

**Not staking.** Nothing is locked. Nothing accrues over time through locking. The system does not benefit holders who lock their tokens into any contract. Holding in a standard wallet with full liquidity is treated identically to any other form of holding.

---

## DESIGN PHILOSOPHY

### Why High Frequency

The 30-second cycle was chosen to make the system feel alive. A weekly lottery creates a static environment where the interesting event is rare and the holding period feels passive. A 30-second cycle creates constant activity. There is always a draw that just happened and a draw that is about to happen. The system is always in motion.

High frequency also has economic consequences. Short cycles mean the fee pool is distributed frequently. This prevents large accumulations sitting idle, which would create a perverse incentive to time large token moves around expected pool peaks. With 30-second cycles, the pool never accumulates long enough to be worth gaming on a timing basis.

From a game theory standpoint, high frequency drives toward equilibrium faster. With 2,880 draws per day, the statistical properties of the distribution model emerge quickly rather than requiring weeks of observation. Holders can evaluate whether the system is behaving as specified within hours of observation, not months.

### Why No Staking

Staking mechanisms create a second layer of economic behavior that tends to override the underlying token dynamics. When a token has a high-yield staking contract, the rational behavior for every holder is to stake everything, not to maintain liquid positions. This concentrates supply in the staking contract, reduces market circulation, and makes the on-chain token state a poor reflection of actual economic interest.

Quantumball's distribution is premised on live holder state. If staking existed, the holder ranking would reflect staking contract allocations rather than genuine holder distribution. The staking contract itself would be the largest holder and would need to be excluded, which would require tracking individual staker allocations inside the staking contract — adding a layer of complexity that defeats the simplicity of the live-balance model.

Removing staking removes this problem entirely. Every balance is a real balance. Every ranking reflects actual holdings. The system is simpler and the state is more meaningful.

### Why Live State Matters

Many distribution systems use snapshots — point-in-time recordings of holder state used to allocate future distributions. Snapshots have advantages: they are computationally cheap, they prevent flash-loan style gaming, and they provide predictability for recipients.

Their disadvantage is that they create a disconnect between current economic activity and current distribution eligibility. A holder who sold their position a week ago may still receive distributions from last week's snapshot. A holder who bought yesterday may not receive distributions until the next snapshot cycle. The distribution does not reflect the live economic state of the token.

Quantumball eliminates this disconnect. The state that determines eligibility is the state at execution. There is no lag, no lookback, no snapshot period. If you hold QBALL when the block closes on a draw transaction, your balance at that moment determines your rank. The system reflects economic reality in real time.

This is not without tradeoffs. It creates the theoretical possibility of buying in just before a draw and selling immediately after — receiving a distribution without maintaining a long-term position. This behavior is not prevented. It is, however, self-limiting: the cost of executing such a trade (gas, slippage, transfer fee) must be less than the expected value of one draw's distribution. At standard pool sizes and subset probabilities, this is not expected to be economically profitable on a consistent basis. The 1% transfer fee on each leg of such a trade further reduces its attractiveness.

### Why Rank-Based Not Balance-Based Weights

Balance-magnitude-based weighting would give a holder with 10,000 QBALL one hundred times the weight of a holder with 100 QBALL. This creates winner-take-most dynamics where large holders rapidly accumulate from distributions, increasing their balance, increasing their weight, compounding their advantage.

Rank-based weighting caps the advantage of large holders. The top holder receives weight 100 regardless of whether they hold 1,000,000 QBALL or 10,000 QBALL. The system rewards being in the top 100 and rewards higher rank, but it does not reward token concentration beyond what is needed to maintain rank. This keeps the distribution curve more gradual and prevents rapid consolidation into a small number of addresses.

---

## CONTRACT ARCHITECTURE

```
/contracts
  Quantumball.sol
    │
    ├── ERC20 base (OpenZeppelin ERC20)
    │     ├── _transfer() override
    │     │     ├── fee deduction to feePool
    │     │     └── _updateHolderRanking() called on both sides
    │     └── standard ERC20 interface
    │
    ├── QuantumballDraw
    │     ├── executeDraw()
    │     │     ├── getTop100Holders()
    │     │     ├── generateEntropy()
    │     │     ├── selectWeightedSubset()
    │     │     ├── resolveDistributionPool()
    │     │     └── distribute()
    │     └── draw state: lastDrawBlock, internalSeed
    │
    ├── HolderRankList
    │     ├── upsert(addr, balance)
    │     ├── remove(addr)
    │     └── getTop(n) → address[]
    │     (Implemented as a sorted doubly-linked list
    │      with O(log n) operations via binary heap proxy)
    │
    └── ExclusionList
          ├── addExcluded(addr) [owner only]
          ├── isExcluded(addr) → bool
          └── getExcluded() → address[]
```

### Key Implementation Notes

**Sorted Holder List**: Maintaining a real-time sorted list of holders by balance is the central data structure challenge. Naive iteration over all holders at draw time is O(n) and unacceptable for a 30-second cycle. The implementation maintains a doubly-linked sorted list with O(log n) insertion and deletion, updated on every `_transfer()` call. This shifts the computational cost from draw time (infrequent large burst) to transfer time (frequent small cost), which is a better gas distribution profile for the system's usage pattern.

**Fee Pool Accounting**: The fee pool is a dedicated internal balance tracked as a uint256. It is not held in a separate contract address to reduce gas overhead. The distribution pool draw clears this balance to zero and distributes the full accumulated amount, preventing pool staleness.

**Reentrancy**: `executeDraw()` updates `lastDrawBlock` before calling `distribute()`. The distribution loop uses `_transfer()` which is the standard ERC20 internal transfer — not an external call to unknown contracts. Reentrancy through standard ERC20 transfers is not a risk vector.

**Draw Timing Enforcement**: The block-count-based interval (15 blocks ≈ 30 seconds at 2s/block) is a soft floor. On networks with variable block times, the actual interval may drift slightly. The contract guarantees a minimum interval (15 blocks) but not an exact maximum. A draw that is delayed by a few blocks due to keeper unavailability is still valid; the draw window simply extends until the next `executeDraw()` call.

---

## SECURITY CONSIDERATIONS

### Entropy Manipulation

As discussed in the Entropy section, the primary attack vector is a block proposer who is also a top QBALL holder manipulating `block.prevrandao` to bias their selection probability. The system's defense is that this requires:

1. Being a validator and a top-100 QBALL holder simultaneously
2. Having a specific desired draw outcome that differs from the default outcome
3. Willingness to sacrifice block rewards by skipping slots to achieve the desired RANDAO value

At typical QBALL draw pool sizes during early operation, the expected additional value from guaranteed selection versus base probability (20%+ for top holders) does not approach the cost of missed validator rewards. As the protocol grows and draw pool sizes increase, this assumption should be revisited.

For deployments where this risk is unacceptable, a Chainlink VRF integration path is documented in `/docs/architecture.md`.

### Flash Loan Eligibility Gaming

An attacker could, in theory, use a flash loan to temporarily acquire enough QBALL to enter the top 100 in the block just before a draw, receive a distribution, then exit. This attack requires:

1. The flash loan to be executable within one block relative to the draw block
2. The expected value of the distribution to exceed: flash loan interest + gas cost + 2x transfer fee (buy and sell)
3. A reliable mechanism to predict which block will be the draw block

The 1% transfer fee creates a 2% round-trip cost on this trade. The draw pool must be large enough relative to the flash loan amount for 20% probability of selection to produce a net-positive expected value after fees. Under standard operating conditions, this is expected to require a flash loan sufficiently large that the gas cost alone makes it uneconomical. However, this should be monitored as the protocol's draw pool grows.

If flash loan gaming becomes a demonstrable issue, a minimum holding period (e.g., balance must have been at current level for 2+ blocks) can be added to eligibility checks.

### Keeper Availability

The draw depends on a keeper or bot calling `executeDraw()` every 30 seconds. If the keeper goes offline, draws stop until the keeper resumes. The system does not execute draws automatically; it only executes when called. This is a liveness dependency, not a safety one — missed draws do not corrupt state, they only delay distribution.

Multiple independent keepers are recommended. Because the function is permissionless, any party can run a keeper. The contract does not pay a keeper bonus by default, but an optional keeper fee (small fixed amount from the fee pool per draw execution) can be configured to incentivize keeper participation.

---

## DEPLOYMENT PARAMETERS

| Parameter | Default Value | Description |
|---|---|---|
| `ELIGIBLE_SET_SIZE` | 100 | Holders evaluated per draw |
| `SUBSET_SIZE` | 20 | Recipients selected per draw |
| `DRAW_INTERVAL_BLOCKS` | 15 | Minimum blocks between draws |
| `TRANSFER_FEE_BPS` | 100 | Transfer fee in basis points (1%) |
| `MIN_DISTRIBUTION_THRESHOLD` | 1,000 QBALL | Minimum pool for fee-based draw |
| `EMISSION_PER_DRAW` | 500 QBALL | Emission fallback per draw |
| `TOTAL_SUPPLY` | 1,000,000,000 QBALL | 1 billion total supply |
| `EMISSION_RESERVE` | 300,000,000 QBALL | 30% allocated to emission reserve |
| `INITIAL_FEE_POOL` | 0 | Fee pool starts empty |

Supply allocation at deployment:

```
Total Supply:          1,000,000,000 QBALL
────────────────────────────────────────────
Emission Reserve:        300,000,000  (30%)
Liquidity Provision:     400,000,000  (40%)
Initial Distribution:    200,000,000  (20%)
Development Reserve:     100,000,000  (10%)
────────────────────────────────────────────
```

The development reserve is subject to a 12-month linear vesting schedule enforced by a separate vesting contract. It is excluded from draw eligibility.

The emission reserve at 500 QBALL per draw sustains the system for:

```
300,000,000 / 500 = 600,000 draws
600,000 draws / 2,880 draws per day = 208 days
```

208 days of emission-funded draws gives the fee pool sufficient time to grow to a self-sustaining level. At 1% transfer fee and any meaningful trading volume, the fee pool is expected to replenish faster than the emission fallback is consumed.

---

## CONCLUSION

Quantumball is a straightforward system described accurately. It runs a draw every 30 seconds. It selects 20 of the top 100 holders using deterministic entropy. It distributes tokens from accumulated fees or emission reserve to those recipients. Recipients receive tokens automatically.

The quantum framing is not marketing. Superposition and collapse are the right words for what the contract does. Between draws, all top-100 holders are simultaneously potential recipients. At execution, that state collapses to a fixed outcome. This happens 2,880 times a day.

The system is inspectable. The logic is documented. The parameters are explicit. The source is published.

Hold QBALL. The draw runs without you.

---

*Quantumball. QBALL. Continuous distribution. No interaction required.*
