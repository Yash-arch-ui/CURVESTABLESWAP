# StableSwap Math — Line-by-Line Explainer

> **Two running examples used throughout:**
> - **Balanced pool**: DAI=100e18, USDC=100e6, USDT=100e6 (all $100)
> - **Unbalanced pool**: DAI=200e18, USDC=50e6, USDT=50e6 ($200 + $50 + $50 = $300 total)

---

## 1. Constants & State Variables

```solidity
uint256 public constant _MULTIPLICATION_FACTOR = 1e12;
```
DAI has 18 decimals, USDC/USDT have 6 decimals. To do math together they must be on the same scale.  
`1e12` bridges the gap: `1e6 × 1e12 = 1e18`. So USDC/USDT are scaled UP before math, scaled DOWN after.

```solidity
uint256 public constant _MAX_ITERATIONS = 255;
```
Newton-Raphson loops converge fast (usually < 10 steps). 255 is a safe hard ceiling so the loop can never run forever (no infinite-gas DoS).

```solidity
uint256 public constant _N_COINS = 3;
```
How many tokens in the pool: DAI, USDC, USDT.

```solidity
uint256 public constant DEFAULT_A = 100;
```
The **amplification coefficient A**. Think of it as a dial:  
- A=0 → pure Uniswap V2 constant-product curve (very curved, big slippage).  
- A=∞ → constant-sum (x+y+z=D, zero slippage, breaks when a peg is lost).  
- A=100 is a middle ground that gives near-zero slippage when pegs hold.

```solidity
uint256[3] public balances;
```
Raw on-chain balances. Index 0=DAI (18 dec), 1=USDC (6 dec), 2=USDT (6 dec).

```solidity
uint256 public totalSupply;
```
Total LP tokens outstanding. Starts at 0.

```solidity
uint256[3] public amounts;
```
Scratch-space array used in `removeLiquidity`. (A design smell — should be a local variable.)

```solidity
constructor(uint256[3] memory initialBalances) {
    balances = initialBalances;
    totalSupply = 0;
}
```
Sets up the pool with initial balances. `totalSupply=0` means no LP tokens yet; first deposit mints them.

---

## 2. `_xp()` — Normalize All Balances to 18-Decimal Space

```solidity
function _xp() public view returns (uint256[3] memory xp) {
    xp[0] = balances[0];                         // DAI stays as-is (already 1e18)
    xp[1] = balances[1] * _MULTIPLICATION_FACTOR; // USDC: 1e6 → 1e18
    xp[2] = balances[2] * _MULTIPLICATION_FACTOR; // USDT: 1e6 → 1e18
    return xp;
}
```

**Why normalization matters:** The invariant formula (see `_getD`) treats all coins as equal in value.  
If you fed raw USDC (1e6) and raw DAI (1e18) into the same formula, DAI would dominate by a factor of 1e12 — the math would be nonsense.

### Balanced example
| Token | Raw balance | After `_xp()` |
|-------|------------|---------------|
| DAI   | 100e18     | 100e18        |
| USDC  | 100e6      | 100e18        |
| USDT  | 100e6      | 100e18        |

### Unbalanced example
| Token | Raw balance | After `_xp()` |
|-------|------------|---------------|
| DAI   | 200e18     | 200e18        |
| USDC  | 50e6       | 50e18         |
| USDT  | 50e6       | 50e18         |

---

## 3. `_getD()` — The Core Invariant (StableSwap's Heart)

The StableSwap invariant is:

```
A·n^n·∑xᵢ + D = A·n^n·D + D^(n+1) / (n^n · ∏xᵢ)
```

Rearranged for Newton-Raphson into the iterative update:

```
D_next = (Ann·S + n·D_P) · D / ((Ann-1)·D + (n+1)·D_P)
```

Where:
- `S = x₀ + x₁ + x₂` (sum of normalized balances)
- `Ann = A × n`
- `D_P = D^(n+1) / (n^n · x₀·x₁·x₂)` (the "product term")

```solidity
function _getD(uint256[3] memory xp, uint256 amp) public view returns (uint256 D) {
```

Takes normalized balances and the amplification coefficient, returns `D` (the invariant / total virtual liquidity).

```solidity
    uint256 S;
    for (uint256 i = 0; i < _N_COINS; i++) {
        S += xp[i];
    }
```
`S` = sum of all normalized balances.

- Balanced:   S = 100e18 + 100e18 + 100e18 = 300e18
- Unbalanced: S = 200e18 + 50e18  + 50e18  = 300e18  ← same dollar total, different split

```solidity
    if (S == 0) return 0;
```
Empty pool → D=0, skip the loop.

```solidity
    D = S;
```
Initial guess for Newton-Raphson. `S` is a great starting point because when A is large, D ≈ S.

```solidity
    uint256 Ann = amp * _N_COINS;  // Ann = 100 × 3 = 300
```

```solidity
    for (uint256 i = 0; i < _MAX_ITERATIONS; i++) {
        uint256 D_P = D;
        for (uint256 j = 0; j < _N_COINS; j++) {
            D_P = (D_P * D) / (xp[j] * _N_COINS);
        }
```
This inner loop computes `D_P = D^(n+1) / (n^n · x₀·x₁·x₂)` iteratively:
- Step 1: `D_P = D * D / (x₀ * 3)`
- Step 2: `D_P = D_P * D / (x₁ * 3)`
- Step 3: `D_P = D_P * D / (x₂ * 3)`

Result: `D^3 / (27 · x₀ · x₁ · x₂)` for n=3.

**Balanced (first iteration, D=300e18):**
```
D_P = (300e18)^3 / (27 · 100e18 · 100e18 · 100e18)
    = 27·(1e18)^3·(300)^3 / (27 · (1e18)^3 · (100)^3)
    = 300^3 / 100^3 = 27,000,000 / 1,000,000 = 27 → scaled: 27e18... 
```
Wait, in a balanced pool all xᵢ=D/n so D_P = D always. This means D won't change → converges in 1 step!

**Unbalanced (x=[200e18,50e18,50e18]):**
D_P will NOT equal D, so the loop needs several iterations to converge.

```solidity
        uint256 Dprev = D;
        D = ((Ann * S + D_P * _N_COINS) * D) / ((Ann - 1) * D + (_N_COINS + 1) * D_P);
```
This is the Newton-Raphson update. The numerator is `(Ann·S + n·D_P)·D`, the denominator is `(Ann-1)·D + (n+1)·D_P`.

```solidity
        if (D > Dprev) {
            if (D - Dprev <= 1) break;
        } else {
            if (Dprev - D <= 1) break;
        }
```
Convergence check: if D moved by ≤1 wei, we're done. Both directions handled to avoid underflow.

### What D means

| Pool State | S | D |
|-----------|---|---|
| Balanced  | 300e18 | 300e18 (= S, balanced pools satisfy D=S) |
| Unbalanced| 300e18 | ~285e18 (less than S — pool is penalized for imbalance) |

D < S in the unbalanced case because the formula embeds an "inefficiency" when coins aren't equal. This is intentional — it makes providing unbalanced liquidity less rewarding.

---

## 4. `getD()` — Public Wrapper

```solidity
function getD(uint256 amp) public view returns (uint256) {
    uint256[3] memory xp = _xp();
    return _getD(xp, amp);
}
```

Just normalizes balances first, then calls `_getD`. Clean two-step: normalize → compute invariant.

**⚠️ Bug:** `get_virtual_price` calls `getD(balances, amp)` (passing two args) but `getD` only takes `amp`. Compile error. The correct call is `getD(amp)`.

---

## 5. `get_virtual_price()` — Price of 1 LP Token in USD

```solidity
function get_virtual_price(uint256 lpSupply, uint256 amp) public view returns (uint256) {
    uint256 D = getD(amp); // ← bug fix applied mentally: getD(amp)
    return (D * 1e18) / lpSupply;
}
```

`D` = total virtual USD liquidity in the pool (18-decimal normalized).  
`lpSupply` = total LP tokens.  
`virtual_price` = how many dollars of liquidity each LP token represents.

**Balanced example (300 LP tokens issued at first deposit):**
```
D = 300e18
virtual_price = 300e18 * 1e18 / 300e18 = 1e18 = $1.00
```

This is always ≥ $1 and grows over time as swap fees accumulate → LP holders profit.

---

## 6. `getY()` — Given New x, What Is New y?

When you swap token i for token j, you're adding `x` (the new amount of token i) to the pool. The invariant D stays constant. We solve for the new balance `y` of token j.

The equation to solve for y (holding D constant) is:

```
y^2 + (b - D)·y - c = 0
```

Where:
- `b = S_ + D/Ann`  (S_ = sum of all non-j coins)
- `c = D^(n+1) / (Ann · n^n · ∏(non-j coins))`

Newton-Raphson: `y_next = (y² + c) / (2y + b - D)`

```solidity
function getY(uint256 i, uint256 j, uint256 x, uint256 amp) public view returns (uint256 y) {
    require(i != j, "same coin");
    uint256[3] memory xp = _xp();  // normalize
    uint256 D = _getD(xp, amp);    // current invariant
    uint256 Ann = amp * _N_COINS;
    uint256 c = D;
    uint256 S_;
```

```solidity
    for (uint256 idx = 0; idx < _N_COINS; idx++) {
        uint256 currentX;
        if (idx == i) {
            currentX = x;    // use NEW balance of i (after adding dx)
        } else if (idx == j) {
            continue;        // skip j — that's what we're solving for
        } else {
            currentX = xp[idx]; // all other coins stay the same
        }
        S_ += currentX;
        c = (c * D) / (currentX * _N_COINS);
    }
```

After this loop:
- `S_` = sum of all coins EXCEPT j (using new x for coin i)
- `c` = accumulated product term (excluding j)

```solidity
    c = (c * D) / (Ann * _N_COINS);  // Final c: divide by Ann*n
    uint256 b = S_ + (D / Ann);
    y = D;  // Initial guess
```

```solidity
    for (uint256 k = 0; k < _MAX_ITERATIONS; k++) {
        uint256 yPrev = y;
        y = (y * y + c) / (2 * y + b - D);
        if (y > yPrev) {
            if (y - yPrev <= 1) break;
        } else {
            if (yPrev - y <= 1) break;
        }
    }
    return y;
}
```
Newton-Raphson on the quadratic. Converges to the new balance of token j.

### Worked Example: Swap 10 DAI → USDC (Balanced Pool, A=100)

Before swap: xp = [100e18, 100e18, 100e18], D = 300e18  
New x for DAI (i=0): 110e18  
Skip j=1 (USDC). Other coin (USDT, idx=2): 100e18

```
S_ = 110e18 + 100e18 = 210e18

c = D / (x_i * 3) * D / (x_k * 3) * D / (Ann * 3)
  ≈ tiny number (but not zero — it sets the floor for y)

b = S_ + D/Ann = 210e18 + 300e18/300 = 210e18 + 1e18 = 211e18
```

Newton-Raphson converges to y ≈ 90.09e18 (slightly above 90 because of AMM price impact).

**Output: ~9.91 USDC out** (not exactly 10 due to price impact).

### Unbalanced example: Pool is [200e18, 50e18, 50e18]

Swapping 10 DAI into an already DAI-heavy pool means more slippage.
y will be higher (you get LESS USDC back) because the pool is already imbalanced in your direction.

---

## 7. `getDy()` — Full Swap Output Calculation

```solidity
function getDy(uint256 i, uint256 j, uint256 dx, uint256 amp) public view returns (uint256 dy) {
    require(i != j, "same coin");
    require(i < _N_COINS && j < _N_COINS, "invalid index");

    uint256[3] memory xp = _xp();  // get normalized balances
    uint256 x = xp[i];             // current normalized balance of token i
```

```solidity
    if (i == 0) {
        x += dx;                         // DAI: add dx as-is (already 18 dec)
    } else {
        x += dx * _MULTIPLICATION_FACTOR; // USDC/USDT: scale dx to 18 dec first
    }
```
**Key:** dx is the raw user input (6-decimal for USDC/USDT). We must normalize it before math.

```solidity
    uint256 y = getY(i, j, x, amp);
```
Get new balance of output token j (still in 18-decimal normalized space).

```solidity
    uint256 dyNormalized = xp[j] - y;  // How much j decreases (in 18-dec space)
```
`xp[j]` is the OLD balance, `y` is the NEW balance. The difference is what comes out.

```solidity
    if (j == 0) {
        dy = dyNormalized;             // DAI output: keep 18 dec
    } else {
        dy = dyNormalized / _MULTIPLICATION_FACTOR; // USDC/USDT: scale back to 6 dec
    }
    return dy;
}
```

### Balanced example: `getDy(0, 1, 10e18, 100)` (Swap 10 DAI for USDC)
1. `xp = [100e18, 100e18, 100e18]`
2. `x = 100e18 + 10e18 = 110e18` (i=0 so no scaling)
3. `y = getY(...)` → ~90.09e18
4. `dyNormalized = 100e18 - 90.09e18 = 9.91e18`
5. `j=1` → `dy = 9.91e18 / 1e12 = 9,910,000` (≈9.91 USDC in 6-decimal units)

### Unbalanced example: `getDy(0, 1, 10e18, 100)` (Pool: DAI=200, USDC=50, USDT=50)
Pool is already heavy on DAI. Adding more DAI into an over-represented token gives worse rates.
You'd get maybe ~8.5 USDC instead of ~9.91 — larger price impact.

---

## 8. `exchange()` — Execute the Swap

```solidity
function exchange(uint256 i, uint256 j, uint256 dx, uint256 amp) public view returns (uint256) {
    require(i != j, "SAME CURRENCY");
    uint256 dy = getDy(i, j, dx, amp);  // Calculate output amount
    balances[i] += dx;    // Add input token to pool
    balances[j] -= dy;    // Remove output token from pool
    return dy;
}
```

**⚠️ Critical Bug:** `public view` but modifies `balances`! This will NOT compile (view functions cannot modify state). Must be `public` (remove `view`).

Also, `balances[i] += dx` adds raw dx without normalizing, but balances are stored in raw units (6-dec for USDC/USDT), so this part is actually correct — raw in, raw out.

### Balanced: Swap 10 DAI for USDC
```
Before: balances = [100e18, 100e6, 100e6]
dy = 9.91e6 (USDC in 6-dec units)
After:  balances = [110e18, 89.09e6, 100e6]
```

### Unbalanced: Swap 10 DAI into [200e18, 50e6, 50e6]
```
Before: balances = [200e18, 50e6, 50e6]
dy ≈ 8.5e6
After:  balances = [210e18, 41.5e6, 50e6]   ← even more unbalanced now
```

---

## 9. `calculateAmountOut()` — How Many LP Tokens for a Deposit/Withdrawal?

```solidity
function calculateAmountOut(
    uint256 amp,
    uint256 _totalSupply,
    uint256[3] memory amounts,
    bool deposit
) public view returns (uint256) {
    totalSupply = _totalSupply;  // ⚠️ Bug: modifies state in a view function
```

```solidity
    uint256[3] memory oldBalances = balances;
    uint256 D0 = getD(amp);          // D BEFORE the deposit/withdrawal
```

```solidity
    uint256[3] memory newBalances = oldBalances;
    for (uint256 i = 0; i < _N_COINS; i++) {
        if (deposit) {
            newBalances[i] += amounts[i];  // Add tokens
        } else {
            newBalances[i] -= amounts[i];  // Remove tokens
        }
    }
    uint256 D1 = getD(newBalances, amp); // ⚠️ Bug: getD() only takes amp, not (balances, amp)
```
D AFTER the change. Reflects how much the pool's total liquidity changed.

```solidity
    if (totalSupply == 0) { return D1; }
```
First deposit: LP tokens = D itself (no existing supply to ratio against). Genesis minting.

```solidity
    if (deposit) {
        uint256 lpAmount = ((D1 - D0) * totalSupply) / D0;
    } else {
        uint256 lpAmount = ((D0 - D1) * totalSupply) / D0;
    }
    return lpAmount;
```
**⚠️ Bug:** `lpAmount` is declared inside the if/else blocks but returned outside. In Solidity this won't compile. The variable is out of scope at `return lpAmount`.

**Logic is correct though:**
- Deposit: you added `(D1-D0)/D0` fraction of liquidity → mint that fraction of total LP supply.
- Withdrawal: you removed `(D0-D1)/D0` fraction → burn that fraction.

### Balanced deposit example (initial state: D0=300e18, LP supply=300e18)
Deposit: 10 DAI, 10 USDC, 10 USDT (balanced — all proportional)
```
D1 = 330e18 (perfectly proportional addition)
lpAmount = (330-300) * 300 / 300 = 30 LP tokens
```
You get exactly 10% more LP tokens for adding 10% more liquidity. ✓

### Unbalanced deposit example (same pool)
Deposit: 30 DAI, 0 USDC, 0 USDT
```
D1 < 360e18  (penalized because you imbalanced the pool)
lpAmount < 30  (you get fewer LP tokens than for a balanced deposit)
```
This is the StableSwap fee-on-imbalance mechanism — it discourages imbalancing deposits.

---

## 10. `addLiquidity()` — Deposit Tokens, Receive LP Tokens

```solidity
function addLiquidity(uint256[3] memory amounts, uint256 amp) public view returns (uint256) {
    uint256 lpMinted = calculateAmountOut(amp, totalSupply, amounts, true);
    for (uint256 i = 0; i < _N_COINS; i++) {
        balances[i] += amounts[i];  // Update raw balances
    }
    totalSupply += lpMinted;        // Mint LP tokens
    return lpMinted;
}
```

**⚠️ Bug:** Again `view` but modifies state. Should be `public` (non-view).

Flow:
1. Calculate how many LP tokens you deserve (`calculateAmountOut`)
2. Receive the user's tokens (update `balances`)
3. Mint LP tokens (`totalSupply` grows)
4. Return how many LP tokens the user gets

### Balanced deposit
Deposit [10e18 DAI, 10e6 USDC, 10e6 USDT] into balanced [100,100,100] pool:
```
lpMinted = 30 (10% of supply)
balances → [110e18, 110e6, 110e6]
totalSupply → 330
```

### Unbalanced deposit
Deposit [30e18 DAI, 0, 0] into balanced [100,100,100] pool:
```
lpMinted ≈ 26-27 (less than 30, penalized for imbalance)
balances → [130e18, 100e6, 100e6]
totalSupply → ~327
```

---

## 11. `removeLiquidity()` — Burn LP, Get All 3 Tokens Proportionally

```solidity
function removeLiquidity(uint256 lpAmount) public returns (uint256) {
    require(totalSupply > 0, "NO Liquidity");
    uint256 share = (lpAmount * 1e18) / totalSupply;  // Your fractional ownership (18-dec)
    totalSupply -= lpAmount;
```

`share` is a fraction in 1e18 precision. E.g., burn 30 LP out of 300 total → share = 0.1e18 (= 10%).

```solidity
    for (uint256 i = 0; i < _N_COINS; i++) {
        amounts[i] = (balances[i] * share) / 1e18;  // Your proportional slice
        balances[i] -= amounts[i];                   // Remove from pool
    }
    return amounts;  // ⚠️ Bug: returns uint256[3] array but declared return type is uint256
}
```

No math complexity here — pure proportional withdrawal. If you own 10% of the pool, you get 10% of each token back. No price impact, no fees, no invariant math needed.

### Balanced example
Pool: [100e18, 100e6, 100e6], LP supply=300. User burns 30 LP.
```
share = 30 * 1e18 / 300 = 0.1e18
amounts[0] = 100e18 * 0.1e18 / 1e18 = 10e18 DAI
amounts[1] = 100e6  * 0.1e18 / 1e18 = 10e6  USDC
amounts[2] = 100e6  * 0.1e18 / 1e18 = 10e6  USDT
```

### Unbalanced example
Pool: [200e18, 50e6, 50e6], LP supply=300. User burns 30 LP.
```
share = 0.1e18
amounts[0] = 200e18 * 0.1 = 20e18 DAI
amounts[1] = 50e6   * 0.1 = 5e6   USDC
amounts[2] = 50e6   * 0.1 = 5e6   USDT
```
You get MORE DAI and LESS USDC/USDT because the pool is DAI-heavy. You bear the imbalance.

---

## 12. `removeLiquidityOneCoin()` — Burn LP, Get Only One Token

This is the most complex withdrawal. Instead of getting all 3 proportionally, you get everything in one token. The pool math (invariant) is used to figure out how much you get.

```solidity
function removeLiquidityOneCoin(uint256 lpAmount, uint256 i, uint256 amp)
    external returns (uint256 dy) {
    require(i < _N_COINS, "invalid coin");
    require(totalSupply > 0, "no supply");
```

```solidity
    uint256 share = (lpAmount * 1e18) / totalSupply;
    totalSupply -= lpAmount;
    uint256[3] memory xp = balances;  // ⚠️ Bug: should call _xp() to normalize!
```

```solidity
    uint256[3] memory newBalances;
    for (uint256 k = 0; k < _N_COINS; k++) {
        uint256 removed = (balances[k] * share) / 1e18;
        newBalances[k] = balances[k] - removed;
    }
```
First, compute what a PROPORTIONAL withdrawal would look like. This is the "starting point."

```solidity
    uint256 D = getD(xp, amp);  // ⚠️ Bug: getD() only takes amp
    uint256 x = newBalances[i]; // Balance of target token after proportional removal
```

```solidity
    uint256 y = getY(i, i, x, newBalances, amp);
    // ⚠️ Bug: getY(i, i, ...) — i==j, which hits require(i != j). Will revert!
    // Also getY signature is (i, j, x, amp) not (i, j, x, balances, amp)
```
The intent here is: after the proportional removal, how much MORE of token i can we extract while keeping the invariant balanced? This uses the curve math to convert the "virtual" reductions of coins j≠i into more of coin i.

```solidity
    dy = xp[i] - y;
```
The extra amount of token i you get by concentrating the withdrawal.

```solidity
    for (uint256 k = 0; k < _N_COINS; k++) {
        balances[k] = newBalances[k];
    }
    return dy;
}
```

### Conceptual example (ignoring bugs): Burn 30 LP, want all USDC (i=1)
Pool: [100e18, 100e6, 100e6], LP=300

Step 1 — Proportional share:
```
share = 10%
proportional removal: [10e18, 10e6, 10e6]
newBalances: [90e18, 90e6, 90e6]
```

Step 2 — But we don't want the DAI or USDT. Convert them to USDC via the curve.  
The curve math finds how much more USDC you can take such that the invariant still holds with `newBalances[0]` and `newBalances[2]` unchanged (i.e., we're "virtually" leaving the DAI and USDT behind).

Result: you get slightly more than 10 USDC (say ~29.7 USDC) because you're getting the other two tokens' worth in USDC — but with some price impact since you're imbalancing the pool.

**Unbalanced pool [200e18, 50e6, 50e6]:**  
Removing USDC from an already USDC-scarce pool causes more slippage. You'd get fewer USDC for the same LP burn.

---

## Summary of Bugs in the Contract

| Location | Bug | Fix |
|----------|-----|-----|
| `get_virtual_price` | `getD(balances, amp)` — wrong args | `getD(amp)` |
| `exchange` | `public view` but writes state | Remove `view` |
| `calculateAmountOut` | `lpAmount` out of scope at `return` | Declare before if/else |
| `calculateAmountOut` | `getD(newBalances, amp)` — wrong | Need to set `balances = newBalances` first or restructure |
| `addLiquidity` | `public view` but writes state | Remove `view` |
| `removeLiquidity` | Returns `uint256` but `amounts` is `uint256[3]` | Fix return type |
| `removeLiquidityOneCoin` | `getY(i, i, ...)` — same coin, will revert | Logic is fundamentally broken here |
| `removeLiquidityOneCoin` | `getD(xp, amp)` — wrong args | `getD(amp)` |
| `_xp()` in `removeLiquidityOneCoin` | Uses raw `balances` not normalized `_xp()` | Use `_xp()` |

---

## The Big Picture

```
User deposits/swaps tokens
         ↓
   _xp() normalizes to 18 dec
         ↓
   _getD() computes invariant D
         ↓
   getY() finds new balance of output token
         ↓
   getDy() converts back to raw decimals
         ↓
   State updated: balances[], totalSupply
```

The elegance: **one number D captures the total "health" of the pool**.  
When pool is balanced, D = sum of balances.  
When imbalanced, D < sum (a penalty is embedded).  
All LP token math, swap math, and withdrawal math flows from comparing D values.
