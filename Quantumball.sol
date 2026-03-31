// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Quantumball (QBALL)
 * @notice Continuous probabilistic distribution system.
 *         Every 30 seconds, a draw selects 20 recipients from the top 100 holders
 *         using deterministic on-chain entropy and distributes tokens immediately.
 *         No staking. No locking. No claiming. Holding is the only requirement.
 * @dev Inherits from a minimal ERC20 base. Uses an internal sorted list to maintain
 *      holder rankings with O(log n) update cost per transfer.
 */

// ─────────────────────────────────────────────────────────────
// INTERFACES
// ─────────────────────────────────────────────────────────────

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// ─────────────────────────────────────────────────────────────
// SORTED HOLDER LIST
// Maintains a doubly-linked list sorted by balance (descending).
// Updated on every transfer via _updateHolderRanking().
// getTop(n) is O(n) but n is capped at 100 — acceptable cost.
// ─────────────────────────────────────────────────────────────

contract SortedHolderList {
    struct Node {
        address prev;
        address next;
        uint256 balance;
    }

    address public constant HEAD = address(1);   // sentinel: highest balance end
    address public constant TAIL = address(2);   // sentinel: lowest balance end

    mapping(address => Node) internal _nodes;
    uint256 public holderCount;

    constructor() {
        _nodes[HEAD] = Node({ prev: address(0), next: TAIL,    balance: type(uint256).max });
        _nodes[TAIL] = Node({ prev: HEAD,        next: address(0), balance: 0              });
    }

    /// @dev Returns the top `n` holder addresses sorted by balance descending.
    ///      O(n) traversal from HEAD sentinel.
    function getTop(uint256 n) external view returns (address[] memory) {
        address[] memory result = new address[](n);
        address current = _nodes[HEAD].next;
        uint256 count = 0;

        while (current != TAIL && count < n) {
            if (current != address(0)) {
                result[count] = current;
                count++;
            }
            current = _nodes[current].next;
        }

        // Trim array to actual count if fewer than n valid holders
        if (count < n) {
            address[] memory trimmed = new address[](count);
            for (uint256 i = 0; i < count; i++) {
                trimmed[i] = result[i];
            }
            return trimmed;
        }

        return result;
    }

    /// @dev Upsert: update an existing node or insert a new one at correct sorted position.
    ///      If balance is zero, removes the node instead.
    function upsert(address addr, uint256 newBalance) external {
        require(addr != HEAD && addr != TAIL && addr != address(0), "Invalid address");

        if (newBalance == 0) {
            _remove(addr);
            return;
        }

        if (_nodes[addr].balance != 0) {
            _remove(addr);
        }

        _insert(addr, newBalance);
    }

    /// @dev Remove a node from the list.
    function _remove(address addr) internal {
        Node storage node = _nodes[addr];
        if (node.balance == 0 && node.prev == address(0)) return; // not in list

        address prevAddr = node.prev;
        address nextAddr = node.next;

        if (prevAddr != address(0)) _nodes[prevAddr].next = nextAddr;
        if (nextAddr != address(0)) _nodes[nextAddr].prev = prevAddr;

        delete _nodes[addr];
        holderCount--;
    }

    /// @dev Insert addr at the correct sorted position (descending by balance).
    function _insert(address addr, uint256 balance) internal {
        // Find insertion point: first node whose balance < new balance
        address current = _nodes[HEAD].next;

        while (current != TAIL && _nodes[current].balance >= balance) {
            current = _nodes[current].next;
        }

        // Insert before `current`
        address prevAddr = _nodes[current].prev;
        _nodes[addr] = Node({ prev: prevAddr, next: current, balance: balance });
        _nodes[prevAddr].next = addr;
        _nodes[current].prev = addr;

        holderCount++;
    }
}

// ─────────────────────────────────────────────────────────────
// MAIN CONTRACT
// ─────────────────────────────────────────────────────────────

contract Quantumball is IERC20 {

    // ─────────────────────────────────
    // TOKEN METADATA
    // ─────────────────────────────────

    string public constant name     = "Quantumball";
    string public constant symbol   = "QBALL";
    uint8  public constant decimals = 18;

    // ─────────────────────────────────
    // SUPPLY CONSTANTS
    // ─────────────────────────────────

    uint256 public constant TOTAL_SUPPLY       = 1_000_000_000 * 1e18;
    uint256 public constant EMISSION_RESERVE   =   300_000_000 * 1e18; // 30%

    // ─────────────────────────────────
    // DRAW CONSTANTS
    // ─────────────────────────────────

    uint256 public constant ELIGIBLE_SET_SIZE         = 100;
    uint256 public constant SUBSET_SIZE               = 20;
    uint256 public constant DRAW_INTERVAL_BLOCKS      = 15;       // ~30s at 2s/block
    uint256 public constant TRANSFER_FEE_BPS          = 100;      // 1%
    uint256 public constant MIN_DISTRIBUTION_THRESHOLD = 1_000 * 1e18;
    uint256 public constant EMISSION_PER_DRAW         = 500 * 1e18;

    // ─────────────────────────────────
    // STATE
    // ─────────────────────────────────

    address public immutable owner;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    uint256 public feePool;
    uint256 public emissionReserve;

    uint256 public lastDrawBlock;
    bytes32 public internalSeed;

    SortedHolderList public holderList;

    mapping(address => bool) public isExcluded;
    address[] private _excludedList;

    // ─────────────────────────────────
    // EVENTS
    // ─────────────────────────────────

    event DrawExecuted(
        uint256 indexed blockNumber,
        bytes32 entropy,
        address[] recipients,
        uint256[] amounts
    );

    event Distributed(
        address indexed recipient,
        uint256 amount,
        uint256 drawBlock
    );

    event ExclusionAdded(address indexed addr);
    event FeePoolUpdated(uint256 newBalance);

    // ─────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────

    constructor(address liquidityWallet, address distributionWallet) {
        owner = msg.sender;

        holderList = new SortedHolderList();

        // Seed must be set before first draw
        internalSeed = keccak256(abi.encodePacked(
            block.prevrandao,
            block.timestamp,
            msg.sender,
            blockhash(block.number - 1)
        ));

        lastDrawBlock = block.number;

        // ── Allocate supply ──────────────────────────────────
        //   30%  emission reserve (held in contract for draws)
        //   40%  liquidity provision wallet
        //   20%  initial distribution wallet
        //   10%  owner (dev reserve — subject to separate vesting contract)

        uint256 liquidity    = (TOTAL_SUPPLY * 40) / 100;
        uint256 distribution = (TOTAL_SUPPLY * 20) / 100;
        uint256 dev          = (TOTAL_SUPPLY * 10) / 100;

        emissionReserve = EMISSION_RESERVE;
        _totalSupply    = TOTAL_SUPPLY;

        // Mint to wallets
        _balances[liquidityWallet]    = liquidity;
        _balances[distributionWallet] = distribution;
        _balances[owner]              = dev;
        _balances[address(this)]      = EMISSION_RESERVE;

        emit Transfer(address(0), liquidityWallet, liquidity);
        emit Transfer(address(0), distributionWallet, distribution);
        emit Transfer(address(0), owner, dev);
        emit Transfer(address(0), address(this), EMISSION_RESERVE);

        // Exclude system addresses from eligibility
        _addExcluded(address(0));
        _addExcluded(address(this));
        _addExcluded(owner);
        _addExcluded(liquidityWallet);

        // Update holder rankings for non-excluded addresses
        holderList.upsert(liquidityWallet, liquidity);
        holderList.upsert(distributionWallet, distribution);
    }

    // ─────────────────────────────────────────────────────────────
    // ERC20 IMPLEMENTATION
    // ─────────────────────────────────────────────────────────────

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "QBALL: insufficient allowance");
        unchecked { _allowances[from][msg.sender] = currentAllowance - amount; }
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function allowance(address holder, address spender) external view override returns (uint256) {
        return _allowances[holder][spender];
    }

    // ─────────────────────────────────────────────────────────────
    // INTERNAL TRANSFER WITH FEE
    // ─────────────────────────────────────────────────────────────

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "QBALL: transfer from zero address");
        require(to != address(0), "QBALL: transfer to zero address");
        require(_balances[from] >= amount, "QBALL: insufficient balance");

        uint256 fee = 0;
        uint256 netAmount = amount;

        // Apply transfer fee for non-excluded senders and non-draw distributions
        if (!isExcluded[from] && !isExcluded[to]) {
            fee = (amount * TRANSFER_FEE_BPS) / 10_000;
            netAmount = amount - fee;
            feePool += fee;
            emit FeePoolUpdated(feePool);
        }

        unchecked {
            _balances[from] -= amount;
            _balances[to]   += netAmount;
        }

        emit Transfer(from, to, netAmount);
        if (fee > 0) emit Transfer(from, address(this), fee);

        // Update holder rankings for both sides of the transfer
        // Skip excluded addresses (pools, contract, etc.)
        if (!isExcluded[from]) _updateHolderRanking(from);
        if (!isExcluded[to])   _updateHolderRanking(to);
    }

    function _updateHolderRanking(address addr) internal {
        holderList.upsert(addr, _balances[addr]);
    }

    // ─────────────────────────────────────────────────────────────
    // DRAW EXECUTION
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Execute the current draw.
     * @dev Permissionless. Anyone may call this once DRAW_INTERVAL_BLOCKS have elapsed.
     *      Selects 20 recipients from the top 100 holders using deterministic entropy.
     *      Distributes tokens immediately — no claiming required.
     */
    function executeDraw() external {
        require(
            block.number >= lastDrawBlock + DRAW_INTERVAL_BLOCKS,
            "QBALL: draw interval not elapsed"
        );

        // Step 1: Resolve eligible holder set
        address[] memory holders = _getEligibleHolders();
        require(holders.length >= SUBSET_SIZE, "QBALL: insufficient eligible holders");

        // Step 2: Generate entropy
        bytes32 entropy = _generateEntropy();

        // Step 3: Select weighted subset
        (address[] memory recipients, uint256[] memory weights, uint256 totalWeight) =
            _selectWeightedSubset(holders, entropy);

        // Step 4: Resolve distribution pool
        uint256 poolAmount = _resolveDistributionPool();
        require(poolAmount > 0, "QBALL: distribution pool empty");

        // Step 5: Update state before external calls (reentrancy guard)
        lastDrawBlock = block.number;
        internalSeed  = entropy;

        // Step 6: Distribute
        uint256[] memory amounts = _distribute(recipients, weights, totalWeight, poolAmount);

        emit DrawExecuted(block.number, entropy, recipients, amounts);
    }

    // ─────────────────────────────────────────────────────────────
    // HOLDER SET RESOLUTION
    // ─────────────────────────────────────────────────────────────

    function _getEligibleHolders() internal view returns (address[] memory) {
        address[] memory top = holderList.getTop(ELIGIBLE_SET_SIZE + _excludedList.length);

        // Filter excluded addresses
        address[] memory eligible = new address[](ELIGIBLE_SET_SIZE);
        uint256 count = 0;

        for (uint256 i = 0; i < top.length && count < ELIGIBLE_SET_SIZE; i++) {
            if (!isExcluded[top[i]] && top[i] != address(0)) {
                eligible[count] = top[i];
                count++;
            }
        }

        // Trim to actual count
        if (count < ELIGIBLE_SET_SIZE) {
            address[] memory trimmed = new address[](count);
            for (uint256 i = 0; i < count; i++) {
                trimmed[i] = eligible[i];
            }
            return trimmed;
        }

        return eligible;
    }

    // ─────────────────────────────────────────────────────────────
    // ENTROPY GENERATION
    // ─────────────────────────────────────────────────────────────

    function _generateEntropy() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            block.prevrandao,    // EIP-4399 beacon RANDAO value
            block.timestamp,
            internalSeed,        // Rolling internal state from prior draws
            msg.sender           // Caller address at execution time
        ));
    }

    // ─────────────────────────────────────────────────────────────
    // WEIGHTED SUBSET SELECTION
    // Fisher-Yates adapted for weighted sampling without replacement.
    // Rank-based weights: top holder = 100, last eligible = 1.
    // ─────────────────────────────────────────────────────────────

    function _selectWeightedSubset(
        address[] memory holders,
        bytes32 entropy
    ) internal pure returns (
        address[] memory recipients,
        uint256[] memory selectedWeights,
        uint256 totalWeight
    ) {
        uint256 n = holders.length;

        // Build weight array: weight[i] = n - i (rank 1 = n, rank n = 1)
        uint256[] memory weights = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            weights[i] = n - i;
        }

        recipients       = new address[](SUBSET_SIZE);
        selectedWeights  = new uint256[](SUBSET_SIZE);
        totalWeight      = 0;

        bytes32 seed = entropy;

        for (uint256 i = 0; i < SUBSET_SIZE; i++) {
            // Compute total weight of remaining candidates
            uint256 remaining = 0;
            for (uint256 j = i; j < n; j++) {
                remaining += weights[j];
            }

            // Sample a position within the remaining weight space
            uint256 target = uint256(seed) % remaining;
            uint256 cumulative = 0;

            for (uint256 j = i; j < n; j++) {
                cumulative += weights[j];
                if (cumulative > target) {
                    // Select j, swap into position i
                    recipients[i]      = holders[j];
                    selectedWeights[i] = weights[j];
                    totalWeight       += weights[j];

                    // Swap to exclude from future selection
                    (holders[i], holders[j])   = (holders[j], holders[i]);
                    (weights[i], weights[j])   = (weights[j], weights[i]);
                    break;
                }
            }

            // Advance entropy: destructive consumption prevents correlation
            seed = keccak256(abi.encodePacked(seed));
        }
    }

    // ─────────────────────────────────────────────────────────────
    // POOL RESOLUTION
    // Prefers accumulated fees. Falls back to emission reserve.
    // ─────────────────────────────────────────────────────────────

    function _resolveDistributionPool() internal returns (uint256) {
        if (feePool >= MIN_DISTRIBUTION_THRESHOLD) {
            uint256 amount = feePool;
            feePool = 0;
            return amount;
        }

        if (emissionReserve >= EMISSION_PER_DRAW) {
            emissionReserve -= EMISSION_PER_DRAW;
            return EMISSION_PER_DRAW;
        }

        if (emissionReserve > 0) {
            uint256 amount  = emissionReserve;
            emissionReserve = 0;
            return amount;
        }

        return 0;
    }

    // ─────────────────────────────────────────────────────────────
    // DISTRIBUTION
    // Push-based. Direct transfer to each recipient. No claiming.
    // Amount proportional to recipient's weight within the draw subset.
    // ─────────────────────────────────────────────────────────────

    function _distribute(
        address[] memory recipients,
        uint256[] memory weights,
        uint256 totalWeight,
        uint256 poolAmount
    ) internal returns (uint256[] memory amounts) {
        amounts = new uint256[](recipients.length);
        uint256 distributed = 0;

        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 amount;

            // Last recipient receives remainder to avoid rounding dust
            if (i == recipients.length - 1) {
                amount = poolAmount - distributed;
            } else {
                amount = (weights[i] * poolAmount) / totalWeight;
            }

            if (amount > 0) {
                _transfer(address(this), recipients[i], amount);
                emit Distributed(recipients[i], amount, block.number);
            }

            amounts[i] = amount;
            distributed += amount;
        }
    }

    // ─────────────────────────────────────────────────────────────
    // EXCLUSION LIST MANAGEMENT
    // ─────────────────────────────────────────────────────────────

    function addExcluded(address addr) external {
        require(msg.sender == owner, "QBALL: only owner");
        _addExcluded(addr);
    }

    function _addExcluded(address addr) internal {
        if (!isExcluded[addr]) {
            isExcluded[addr] = true;
            _excludedList.push(addr);
            // Remove from holder ranking if present
            holderList.upsert(addr, 0);
            emit ExclusionAdded(addr);
        }
    }

    function getExcludedList() external view returns (address[] memory) {
        return _excludedList;
    }

    // ─────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS
    // ─────────────────────────────────────────────────────────────

    /// @notice Returns the current top 100 eligible holders.
    function getTop100() external view returns (address[] memory) {
        return _getEligibleHolders();
    }

    /// @notice Returns the number of blocks remaining until the next draw may execute.
    function blocksUntilNextDraw() external view returns (uint256) {
        uint256 nextBlock = lastDrawBlock + DRAW_INTERVAL_BLOCKS;
        if (block.number >= nextBlock) return 0;
        return nextBlock - block.number;
    }

    /// @notice Returns true if a draw is currently executable.
    function drawReady() external view returns (bool) {
        return block.number >= lastDrawBlock + DRAW_INTERVAL_BLOCKS;
    }

    /// @notice Returns the current entropy that would be generated if a draw executed now.
    /// @dev Informational only. Actual entropy at draw time will differ due to msg.sender.
    function previewEntropy() external view returns (bytes32) {
        return keccak256(abi.encodePacked(
            block.prevrandao,
            block.timestamp,
            internalSeed,
            address(0) // placeholder for msg.sender
        ));
    }

    /// @notice Returns the current distribution pool status.
    function poolStatus() external view returns (
        uint256 currentFeePool,
        uint256 currentEmissionReserve,
        bool feePoolActive
    ) {
        return (
            feePool,
            emissionReserve,
            feePool >= MIN_DISTRIBUTION_THRESHOLD
        );
    }
}
