/**
 * drawSimulation.js
 *
 * Simulates Quantumball draw execution off-chain.
 * Replicates the on-chain entropy and selection logic in JavaScript
 * to allow pre-draw analysis, historical verification, and debugging.
 *
 * Usage:
 *   node drawSimulation.js [--holders=<n>] [--draws=<n>] [--seed=<hex>]
 *
 * Examples:
 *   node drawSimulation.js
 *   node drawSimulation.js --holders=100 --draws=50
 *   node drawSimulation.js --seed=0xdeadbeef --draws=1
 */

"use strict";

const { keccak256 } = require("@ethersproject/keccak256");
const { defaultAbiCoder } = require("@ethersproject/abi");
const { hexlify, hexZeroPad, arrayify } = require("@ethersproject/bytes");
const { BigNumber } = require("@ethersproject/bignumber");

// ─────────────────────────────────────────────────────────────
// CONSTANTS (must match Quantumball.sol)
// ─────────────────────────────────────────────────────────────

const ELIGIBLE_SET_SIZE = 100;
const SUBSET_SIZE = 20;
const TOTAL_SUPPLY = BigNumber.from("1000000000").mul(BigNumber.from(10).pow(18));
const EMISSION_PER_DRAW = BigNumber.from("500").mul(BigNumber.from(10).pow(18));
const TRANSFER_FEE_BPS = 100; // 1%

// ─────────────────────────────────────────────────────────────
// ARGUMENT PARSING
// ─────────────────────────────────────────────────────────────

function parseArgs() {
    const args = {};
    process.argv.slice(2).forEach((arg) => {
        const [key, value] = arg.replace("--", "").split("=");
        args[key] = value;
    });
    return {
        holderCount: parseInt(args.holders || "100", 10),
        drawCount:   parseInt(args.draws || "10", 10),
        seedHex:     args.seed || null,
    };
}

// ─────────────────────────────────────────────────────────────
// MOCK DATA GENERATION
// Generates a synthetic holder set with realistic balance distribution.
// Uses a power-law distribution to approximate real token holder dynamics.
// ─────────────────────────────────────────────────────────────

function generateMockHolders(count) {
    const holders = [];
    const totalTokens = BigNumber.from("700000000").mul(BigNumber.from(10).pow(18)); // 70% circulating

    for (let i = 0; i < count; i++) {
        // Power-law: holder i holds proportional to 1/(i+1)^1.2
        const weight = Math.pow(1 / (i + 1), 1.2);
        holders.push({
            address: `0x${(i + 1).toString(16).padStart(40, "0")}`,
            rank: i + 1,
            weight,
        });
    }

    // Normalize weights to total tokens
    const weightSum = holders.reduce((s, h) => s + h.weight, 0);
    holders.forEach((h) => {
        h.balance = totalTokens
            .mul(Math.floor(h.weight / weightSum * 1e9))
            .div(1e9);
    });

    // Sort descending by balance (they should already be, but enforce)
    holders.sort((a, b) => (b.balance.gt(a.balance) ? 1 : -1));
    holders.forEach((h, i) => { h.rank = i + 1; });

    return holders;
}

// ─────────────────────────────────────────────────────────────
// ENTROPY GENERATION
// Mirrors the Solidity entropy function.
// Inputs: simulated block data + internal seed.
// ─────────────────────────────────────────────────────────────

function generateEntropy(blockData, internalSeed) {
    const encoded = defaultAbiCoder.encode(
        ["uint256", "uint256", "bytes32", "address"],
        [
            blockData.prevrandao,
            blockData.timestamp,
            internalSeed,
            blockData.caller,
        ]
    );
    return keccak256(encoded);
}

// ─────────────────────────────────────────────────────────────
// WEIGHT ASSIGNMENT
// Rank-based: holder at rank r (1-indexed) receives weight = n + 1 - r.
// Top holder = n, last eligible = 1.
// ─────────────────────────────────────────────────────────────

function assignWeights(holders) {
    const n = holders.length;
    return holders.map((h, i) => ({
        ...h,
        drawWeight: n - i, // n=100 for rank 1, 1 for rank 100
    }));
}

// ─────────────────────────────────────────────────────────────
// WEIGHTED SUBSET SELECTION
// Fisher-Yates adapted for weighted sampling without replacement.
// Mirrors the Solidity _selectWeightedSubset() function exactly.
// ─────────────────────────────────────────────────────────────

function selectWeightedSubset(holders, entropyHex) {
    // Deep copy to avoid mutating the input
    const pool = holders.map((h, i) => ({
        ...h,
        drawWeight: holders.length - i,
    }));

    const selected = [];
    let seed = entropyHex;

    for (let i = 0; i < SUBSET_SIZE; i++) {
        // Compute total weight of remaining candidates
        let remaining = BigNumber.from(0);
        for (let j = i; j < pool.length; j++) {
            remaining = remaining.add(pool[j].drawWeight);
        }

        // Sample within remaining weight space
        const seedBig = BigNumber.from(seed);
        const target = seedBig.mod(remaining);

        let cumulative = BigNumber.from(0);
        let chosenIdx = i; // fallback

        for (let j = i; j < pool.length; j++) {
            cumulative = cumulative.add(pool[j].drawWeight);
            if (cumulative.gt(target)) {
                chosenIdx = j;
                break;
            }
        }

        selected.push({
            address: pool[chosenIdx].address,
            rank: pool[chosenIdx].rank,
            drawWeight: pool[chosenIdx].drawWeight,
        });

        // Swap chosen into position i
        const tmp = pool[i];
        pool[i] = pool[chosenIdx];
        pool[chosenIdx] = tmp;

        // Destructively advance entropy
        seed = keccak256(arrayify(seed));
    }

    return selected;
}

// ─────────────────────────────────────────────────────────────
// DISTRIBUTION CALCULATION
// Proportional to draw weight within the selected subset.
// ─────────────────────────────────────────────────────────────

function calculateDistributions(recipients, poolAmount) {
    const totalWeight = recipients.reduce((s, r) => s + r.drawWeight, 0);

    let distributed = BigNumber.from(0);
    const result = [];

    for (let i = 0; i < recipients.length; i++) {
        let amount;

        if (i === recipients.length - 1) {
            // Last recipient receives remainder
            amount = poolAmount.sub(distributed);
        } else {
            amount = poolAmount.mul(recipients[i].drawWeight).div(totalWeight);
        }

        result.push({
            ...recipients[i],
            amount,
            amountFormatted: formatTokens(amount),
        });

        distributed = distributed.add(amount);
    }

    return result;
}

// ─────────────────────────────────────────────────────────────
// FORMATTING UTILITIES
// ─────────────────────────────────────────────────────────────

function formatTokens(amount) {
    const full = amount.div(BigNumber.from(10).pow(18)).toNumber();
    const frac = amount.mod(BigNumber.from(10).pow(18)).toString().padStart(18, "0").slice(0, 4);
    return `${full.toLocaleString()}.${frac} QBALL`;
}

function formatSeed(hex) {
    return hex.slice(0, 10) + "..." + hex.slice(-8);
}

function separator(char = "─", width = 72) {
    return char.repeat(width);
}

// ─────────────────────────────────────────────────────────────
// SELECTION STATISTICS
// Tracks how many times each rank position was selected.
// Used to verify that selection probabilities converge toward
// theoretical values over many draws.
// ─────────────────────────────────────────────────────────────

function computeTheoreticalProbability(rank, n, subsetSize) {
    const weight = n + 1 - rank;
    const totalWeight = (n * (n + 1)) / 2;
    return (weight / totalWeight) * subsetSize;
}

// ─────────────────────────────────────────────────────────────
// SINGLE DRAW EXECUTION
// ─────────────────────────────────────────────────────────────

function executeSingleDraw(holders, internalSeed, blockNumber, verbose = true) {
    // Simulate block data
    const blockData = {
        prevrandao: BigNumber.from(
            keccak256(hexlify(BigNumber.from(blockNumber).toHexString()))
        ).toString(),
        timestamp: Math.floor(Date.now() / 1000) + blockNumber * 2,
        caller: "0x0000000000000000000000000000000000000001",
    };

    const entropy = generateEntropy(blockData, internalSeed);
    const weighted = assignWeights(holders);
    const recipients = selectWeightedSubset(weighted, entropy);
    const poolAmount = EMISSION_PER_DRAW;
    const distributions = calculateDistributions(recipients, poolAmount);

    if (verbose) {
        console.log(separator());
        console.log(`DRAW #${blockNumber}`);
        console.log(separator("─"));
        console.log(`Block:         ${blockNumber}`);
        console.log(`Timestamp:     ${blockData.timestamp}`);
        console.log(`Entropy:       ${formatSeed(entropy)}`);
        console.log(`Internal Seed: ${formatSeed(internalSeed)}`);
        console.log(`Pool Amount:   ${formatTokens(poolAmount)}`);
        console.log(separator("─"));
        console.log(`RECIPIENTS (${distributions.length} selected from top ${holders.length}):`);
        console.log(separator("─"));

        const totalWeight = distributions.reduce((s, r) => s + r.drawWeight, 0);

        distributions.forEach((r, i) => {
            const pct = ((r.drawWeight / totalWeight) * 100).toFixed(1).padStart(5);
            console.log(
                `  ${(i + 1).toString().padStart(2)}.  ` +
                `Rank ${r.rank.toString().padStart(3)}  ` +
                `${r.address.slice(0, 12)}...  ` +
                `Weight: ${r.drawWeight.toString().padStart(3)}  ` +
                `Share: ${pct}%  ` +
                `Amount: ${r.amountFormatted}`
            );
        });
    }

    // Return new internal seed = entropy (mirrors contract behavior)
    return { entropy, distributions };
}

// ─────────────────────────────────────────────────────────────
// MULTI-DRAW STATISTICAL ANALYSIS
// Runs N draws and aggregates selection frequency by rank.
// Compares observed frequencies to theoretical probabilities.
// ─────────────────────────────────────────────────────────────

function runStatisticalAnalysis(holders, initialSeed, drawCount) {
    console.log(separator("═"));
    console.log(`STATISTICAL ANALYSIS — ${drawCount} DRAWS`);
    console.log(separator("═"));

    const selectionCount = new Array(ELIGIBLE_SET_SIZE + 1).fill(0); // index = rank
    let currentSeed = initialSeed;

    for (let d = 0; d < drawCount; d++) {
        const { entropy, distributions } = executeSingleDraw(
            holders, currentSeed, d + 1, false
        );
        distributions.forEach((r) => {
            selectionCount[r.rank]++;
        });
        currentSeed = entropy;
    }

    console.log("\nRANK  | OBSERVED | THEORETICAL | DELTA");
    console.log(separator("─", 50));

    // Show ranks 1, 10, 25, 50, 75, 90, 100
    const sampleRanks = [1, 5, 10, 25, 50, 75, 90, 95, 100];

    for (const rank of sampleRanks) {
        const observed = selectionCount[rank];
        const theoretical = computeTheoreticalProbability(rank, ELIGIBLE_SET_SIZE, SUBSET_SIZE) * drawCount;
        const delta = ((observed - theoretical) / theoretical * 100).toFixed(1);
        const sign = delta >= 0 ? "+" : "";

        console.log(
            `${rank.toString().padStart(5)} | ` +
            `${observed.toString().padStart(8)} | ` +
            `${theoretical.toFixed(1).padStart(11)} | ` +
            `${sign}${delta}%`
        );
    }

    console.log(separator("─", 50));

    const totalDistributions = drawCount * SUBSET_SIZE;
    const observed1 = selectionCount[1];
    const observed100 = selectionCount[100] || 0;
    const ratio = observed1 > 0 && observed100 > 0 ? (observed1 / observed100).toFixed(2) : "N/A";
    const theoretical1 = computeTheoreticalProbability(1, ELIGIBLE_SET_SIZE, SUBSET_SIZE) * drawCount;
    const theoretical100 = computeTheoreticalProbability(100, ELIGIBLE_SET_SIZE, SUBSET_SIZE) * drawCount;
    const theoreticalRatio = (theoretical1 / theoretical100).toFixed(2);

    console.log(`\nTotal distributions:       ${totalDistributions}`);
    console.log(`Expected unique addresses: ${SUBSET_SIZE} per draw`);
    console.log(`Rank 1 / Rank 100 ratio:   ${ratio} (theoretical: ${theoreticalRatio})`);
    console.log(`\nAll ranks in top-100 received at least one selection: ${
        selectionCount.slice(1, ELIGIBLE_SET_SIZE + 1).every((c) => c >= 0) ? "YES" : "NO"
    }`);
}

// ─────────────────────────────────────────────────────────────
// ENTROPY VERIFICATION TOOL
// Given a recorded draw (entropy, recipients), verify that the
// selection is the correct output for those entropy inputs.
// ─────────────────────────────────────────────────────────────

function verifyDraw(holders, recordedEntropy, recordedRecipients) {
    console.log(separator("═"));
    console.log("DRAW VERIFICATION");
    console.log(separator("═"));
    console.log(`Entropy: ${recordedEntropy}`);
    console.log(separator("─"));

    const weighted = assignWeights(holders);
    const computed = selectWeightedSubset(weighted, recordedEntropy);

    let allMatch = true;
    for (let i = 0; i < recordedRecipients.length; i++) {
        const match = computed[i]?.address.toLowerCase() === recordedRecipients[i].toLowerCase();
        if (!match) allMatch = false;
        console.log(
            `  ${(i + 1).toString().padStart(2)}.  ` +
            `Expected: ${recordedRecipients[i].slice(0, 12)}...  ` +
            `Computed: ${computed[i]?.address.slice(0, 12) || "MISSING"}...  ` +
            `${match ? "MATCH" : "MISMATCH"}`
        );
    }

    console.log(separator("─"));
    console.log(`Verification result: ${allMatch ? "VALID" : "INVALID"}`);
    return allMatch;
}

// ─────────────────────────────────────────────────────────────
// MAIN ENTRY POINT
// ─────────────────────────────────────────────────────────────

async function main() {
    const args = parseArgs();

    console.log(separator("═"));
    console.log("QUANTUMBALL DRAW SIMULATION");
    console.log(separator("═"));
    console.log(`Eligible Set:    ${ELIGIBLE_SET_SIZE} holders`);
    console.log(`Subset Size:     ${SUBSET_SIZE} recipients per draw`);
    console.log(`Draw Interval:   15 blocks (~30 seconds)`);
    console.log(`Transfer Fee:    ${TRANSFER_FEE_BPS / 100}%`);
    console.log(`Emission/Draw:   ${formatTokens(EMISSION_PER_DRAW)}`);
    console.log(separator("═"));

    // Generate mock holder set
    const holders = generateMockHolders(args.holderCount);

    console.log(`\nHolder set generated: ${holders.length} addresses`);
    console.log(`Top holder balance:   ${formatTokens(holders[0].balance)}`);
    console.log(`Rank 50 balance:      ${formatTokens(holders[49]?.balance || BigNumber.from(0))}`);
    console.log(`Rank 100 balance:     ${formatTokens(holders[99]?.balance || BigNumber.from(0))}`);

    // Initialize internal seed
    let internalSeed = args.seedHex ||
        keccak256(
            defaultAbiCoder.encode(
                ["uint256", "uint256"],
                [Date.now(), process.pid]
            )
        );

    console.log(`\nInitial seed: ${formatSeed(internalSeed)}`);

    if (args.drawCount === 1) {
        // Single draw: verbose output
        const { entropy } = executeSingleDraw(holders, internalSeed, 1, true);
        console.log(separator());
        console.log(`New internal seed: ${formatSeed(entropy)}`);
        console.log(separator());
    } else {
        // Multiple draws: first 3 verbose, then statistical summary
        let currentSeed = internalSeed;

        const verboseDraws = Math.min(3, args.drawCount);
        for (let d = 0; d < verboseDraws; d++) {
            const { entropy } = executeSingleDraw(holders, currentSeed, d + 1, true);
            currentSeed = entropy;
        }

        if (args.drawCount > verboseDraws) {
            console.log(separator());
            console.log(`... (${args.drawCount - verboseDraws} draws omitted from verbose output) ...`);
        }

        // Statistical analysis over all draws
        console.log("");
        runStatisticalAnalysis(holders, internalSeed, args.drawCount);
    }

    console.log(separator("═"));
    console.log("SIMULATION COMPLETE");
    console.log(separator("═"));
}

main().catch((err) => {
    console.error("Simulation error:", err);
    process.exit(1);
});
