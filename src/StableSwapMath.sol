// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// Curve-style stableswap invariant math for a 3-coin pool
contract StableSwapMath {
    // Scales token decimals up so all coins are compared at a common precision
    uint256 public constant _MULTIPLICATION_FACTOR = 1e12;
    // Newton's method converges fast; cap iterations as a safety bound
    uint256 public constant _MAX_ITERATIONS = 255;
    uint256 public constant _N_COINS = 3;
    uint256 public constant DEFAULT_A = 100;
    uint256 public constant fee = 4_000_000; // 0.04%
    uint256 public constant FEE_DENOMINATOR = 10_000_000_000;

    bool private _locked;

    uint256[3] public balances;
    uint256 public totalSupply;
    uint256[3] public amounts;
    // Actual ERC20 token addresses held by this pool
    address[3] public coins;

    constructor(uint256[3] memory initialBalances, address[3] memory initialCoins) {
        balances = initialBalances;
        coins = initialCoins;
        totalSupply = 0;
    }

    // Guards against reentrancy using a simple lock flag
    modifier nonReentrant() {
        require(!_locked, "Reentrancy detected");
        _locked = true;
        _;
        _locked = false;
    }

    // Normalize raw balances to a common precision (coin 0 stays, others scaled up)
    function _xp(uint256[3] memory _balances) public pure returns (uint256[3] memory xp) {
        xp[0] = _balances[0];
        xp[1] = _balances[1] * _MULTIPLICATION_FACTOR;
        xp[2] = _balances[2] * _MULTIPLICATION_FACTOR;
        return xp;
    }

    // Computes invariant D via Newton's iteration on the stableswap equation.
    // D stays roughly constant when prices are ~1:1; it equals the total liquidity.
    function _getD(uint256[3] memory xp, uint256 amp) public pure returns (uint256 D) {
        uint256 S;

        for (uint256 i = 0; i < _N_COINS; i++) {
            S += xp[i];
        }

        if (S == 0) {
            return 0;
        }

        D = S;
        uint256 Ann = amp * _N_COINS;

        for (uint256 i = 0; i < _MAX_ITERATIONS; i++) {
            uint256 D_P = D;

            for (uint256 j = 0; j < _N_COINS; j++) {
                D_P = (D_P * D) / (xp[j] * _N_COINS);
            }

            uint256 Dprev = D;

            // Newton step: refines D until the change between iterations is <= 1
            D = ((Ann * S + D_P * _N_COINS) * D) / ((Ann - 1) * D + (_N_COINS + 1) * D_P);

            if (D > Dprev) {
                if (D - Dprev <= 1) {
                    break;
                }
            } else {
                if (Dprev - D <= 1) {
                    break;
                }
            }
        }

        return D;
    }

    // Convenience wrapper: computes D directly from raw balances
    function _getD_balances(uint256[3] memory balances_, uint256 amp) internal pure returns (uint256) {
        uint256[3] memory xp = _xp(balances_);
        return _getD(xp, amp);
    }

    // Solves for the balance of coin j after swapping x of coin i into the pool.
    // Uses the invariant D (held constant) and Newton's method to find the new y.
    function _getY(uint256 i, uint256 j, uint256 x, uint256 amp) internal view returns (uint256 y) {
        require(i != j, "same coin");
        require(i < _N_COINS, "INVALID");
        require(j < _N_COINS, "INVALID");

        uint256[3] memory xp = _xp(balances);

        uint256 D = _getD(xp, amp);
        uint256 Ann = amp * _N_COINS;

        uint256 c = D;
        uint256 S_;

        // Build the sum and product terms over all coins except j
        // (coin i uses the new amount x, coin j is excluded as the unknown)
        for (uint256 idx = 0; idx < _N_COINS; idx++) {
            uint256 currentX;

            if (idx == i) {
                currentX = x;
            } else if (idx == j) {
                continue;
            } else {
                currentX = xp[idx];
            }

            S_ += currentX;
            c = (c * D) / (currentX * _N_COINS);
        }

        c = (c * D) / (Ann * _N_COINS);
        uint256 b = S_ + (D / Ann);

        // Newton iteration to converge on the new balance y
        y = D;

        for (uint256 k = 0; k < _MAX_ITERATIONS; k++) {
            uint256 yPrev = y;
 
            y = (y * y + c) / ((2 * y) + b - D);

            if (y > yPrev) {
                if (y - yPrev <= 1) {
                    break;
                }
            } else {
                if (yPrev - y <= 1) {
                    break;
                }
            }
        }

        return y;
    }

    // Returns how many coins of j come out when dx of coin i goes in, after normalization.
    function _getDy(uint256 i, uint256 j, uint256 dx, uint256 amp) internal view returns (uint256 dy) {
        require(i != j, "same coin");
        require(i < _N_COINS && j < _N_COINS, "invalid index");

        uint256[3] memory xp = _xp(balances);
        uint256 x = xp[i];

        // Scale dx to normalized precision, then find the new pool state
        if (i == 0) {
            x += dx;
        } else {
            x += dx * _MULTIPLICATION_FACTOR;
        }

        uint256 y = _getY(i, j, x, amp);
        // Difference between old and new balance of j is the output amount
        uint256 dyNormalized = xp[j] - y;

        // Convert back to the token's native decimals
        if (j == 0) {
            dy = dyNormalized;
        } else {
            dy = dyNormalized / _MULTIPLICATION_FACTOR;
        }

        return dy;
    }

    // Mints (deposit) or burns (withdraw) LP tokens proportional to the change in D.
    // On first deposit with zero supply, LP minted simply equals D1.
    function _calculateAmountOut(uint256 amp, uint256 _totalSupply, uint256[3] memory amounts_, bool deposit)
        internal
        view
        returns (uint256 lpAmount)
    {
        uint256[3] memory oldBalances = balances;
        // D0 = invariant before, D1 = invariant after applying the deposit/withdrawal
        uint256 D0 = _getD_balances(oldBalances, amp);
        uint256[3] memory newBalances = oldBalances;

        for (uint256 i = 0; i < _N_COINS; i++) {
            if (deposit) {
                newBalances[i] += amounts_[i];
            } else {
                newBalances[i] -= amounts_[i];
            }
        }

        uint256 D1 = _getD_balances(newBalances, amp);
        if (_totalSupply == 0) {
            return D1;
        }
        if (deposit) {
            lpAmount = ((D1 - D0) * _totalSupply) / D0;
        } else {
            lpAmount = ((D0 - D1) * _totalSupply) / D0;
        }

        return lpAmount;
    }

    // Solves for the balance of coin j when D changes (e.g. LP withdrawal of one coin)
    function _getYD(uint256 j, uint256[3] memory xp_, uint256 D, uint256 amp) internal pure returns (uint256 y) {
        uint256 Ann = amp * _N_COINS;
        uint256 c = D;
        uint256 S_;
        for (uint256 k = 0; k < _N_COINS; k++) {
            if (k == j) continue;
            S_ += xp_[k];
            c = (c * D) / (xp_[k] * _N_COINS);
        }
        c = (c * D) / (Ann * _N_COINS);
        uint256 b = S_ + (D / Ann);
        y = D;
        // Same Newton iteration as _getY, but with D given instead of derived
        for (uint256 k = 0; k < _MAX_ITERATIONS; k++) {
            uint256 yPrev = y;
            y = (y * y + c) / (2 * y + b - D);
            if (y > yPrev ? y - yPrev <= 1 : yPrev - y <= 1) break;
        }
        return y;
    }

    // Public read-only wrappers around the internal math
    function getD(uint256[3] memory balances_, uint256 amp) external view returns (uint256) {
        return _getD_balances(balances_, amp);
    }

    function getY(uint256 i, uint256 j, uint256 x, uint256 amp) external view returns (uint256) {
        return _getY(i, j, x, amp);
    }

    function getDy(uint256 i, uint256 j, uint256 dx, uint256 amp) external view returns (uint256) {
        return _getDy(i, j, dx, amp);
    }

    function calculateAmountOut(uint256 amp, uint256 _totalSupply, uint256[3] memory amounts_, bool deposit)
        external
        view
        returns (uint256)
    {
        return _calculateAmountOut(amp, _totalSupply, amounts_, deposit);
    }

    // LP token price in 1e18 terms: invariant D per LP unit
    function get_virtual_price(uint256 lpSupply, uint256 amp) external view returns (uint256) {
        require(lpSupply > 0, "ZERO_SUPPLY");
        uint256 D = _getD_balances(balances, amp);
        return (D * 1e18) / lpSupply;
    }

    // Swap dx of coin i for dy of coin j: pulls tokens in, applies fee, sends output out
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 amp) public nonReentrant returns (uint256) {
        require(i != j, "SAME CURRENCY");
        require(i < _N_COINS && j < _N_COINS, "INVALID");
        //S1
        IERC20(coins[i]).transferFrom(msg.sender, address(this), dx);

        // Calls the internal version to bypass lock
        //S2
        uint256 dy = _getDy(i, j, dx, amp);
        // Deduct the swap fee from the output amount
        uint256 dy_fee = dy * fee / FEE_DENOMINATOR;
        dy -= dy_fee;

        balances[i] += dx;
        balances[j] -= dy;
        IERC20(coins[j]).transfer(msg.sender, dy);

        return dy;
    }

    // Deposit all three coins and mint LP tokens based on the resulting D increase
    function addLiquidity(uint256[3] memory amounts_, uint256 amp) public nonReentrant returns (uint256) {
        // Calls the internal version to bypass lock
        uint256 lpMinted = _calculateAmountOut(amp, totalSupply, amounts_, true);

        for (uint256 i = 0; i < _N_COINS; i++) {
            balances[i] += amounts_[i];
            IERC20(coins[i]).transferFrom(msg.sender, address(this), amounts_[i]);
        }

        totalSupply += lpMinted;

        return lpMinted;
    }

    // Burn LP tokens and withdraw a proportional share of every coin in the pool
    function removeLiquidity(uint256 lpAmount) public nonReentrant returns (uint256[3] memory) {
        require(totalSupply > 0, "NO LIQUIDITY");
        require(lpAmount <= totalSupply, "INSUFFICIENT_LP");
        // Caller's ownership fraction in 1e18 precision
        uint256 share = (lpAmount * 1e18) / totalSupply;

        totalSupply -= lpAmount;

        for (uint256 i = 0; i < _N_COINS; i++) {
            amounts[i] = (balances[i] * share) / 1e18;
            balances[i] -= amounts[i];
            if (amounts[i] > 0) {
                require(IERC20(coins[i]).transfer(msg.sender, amounts[i]), "Transfer failed");
            }
        }

        return amounts;
    }

    // Burn LP tokens and withdraw only coin i, using _getYD to keep the invariant balanced
    function removeLiquidityOneCoin(uint256 lpAmount, uint256 i, uint256 amp)
        external
        nonReentrant
        returns (uint256 dy)
    {
        require(i < _N_COINS, "invalid coin");
        require(totalSupply > 0, "no supply");
        require(lpAmount <= totalSupply, "INSUFFICIENT_LP");

        uint256 share = (lpAmount * 1e18) / totalSupply;
        totalSupply -= lpAmount;
        
        // Calls the internal version to bypass lock
        // D0 = current invariant; d1 = what D should be after removing the LP share
        uint256 d0 = _getD_balances(balances, DEFAULT_A);

        uint256 d1 = (d0 * (1e18 - share)) / 1e18;
        uint256[3] memory normalizedBalances = _xp(balances);
        // New balance of coin i that satisfies the reduced invariant d1
        uint256 targetBalancerequired = _getYD(i, normalizedBalances, d1, DEFAULT_A);

        uint256 dyNormalized = normalizedBalances[i] - targetBalancerequired;

        // Convert from normalized precision back to the token's native decimals
        if (i == 0) {
            dy = dyNormalized;
        } else {
            dy = dyNormalized / _MULTIPLICATION_FACTOR;
        }

        balances[i] -= dy;
        require(IERC20(coins[i]).transfer(msg.sender, dy), "Transfer Failed ");
        return dy;
    }
}
