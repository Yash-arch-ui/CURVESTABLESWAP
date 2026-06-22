// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract StableSwapMath {

    uint256 public constant _MULTIPLICATION_FACTOR = 1e12;
    uint256 public constant _MAX_ITERATIONS = 255;
    uint256 public constant _N_COINS = 3;
    uint256 public constant DEFAULT_A = 100;

    uint256[3] public balances;
    uint256 public totalSupply;
    uint256[3] public amounts;

    constructor(uint256[3] memory initialBalances) {
        balances = initialBalances;
        totalSupply = 0;
    }

    function _xp(uint256[3] memory _balances) public pure returns (uint256[3] memory xp) {
        xp[0] = _balances[0];
        xp[1] = _balances[1] * _MULTIPLICATION_FACTOR;
        xp[2] = _balances[2] * _MULTIPLICATION_FACTOR;
        return xp;
    }

    function _getD(
        uint256[3] memory xp,
        uint256 amp
    ) public pure returns (uint256 D) {
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

            D =
                ((Ann * S + D_P * _N_COINS) * D) /
                ((Ann - 1) * D + (_N_COINS + 1) * D_P);

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

    function getD(
        uint256[3] memory balances_,
        uint256 amp
    ) public pure returns (uint256) {
        uint256[3] memory xp = _xp(balances_);
        return _getD(xp, amp);
    }

    function get_virtual_price(
        uint256 lpSupply,
        uint256 amp
    ) public view returns (uint256) {
        uint256 D = getD(balances, amp);
        return (D * 1e18) / lpSupply;
    }

    function getY(
        uint256 i,
        uint256 j,
        uint256 x,
        uint256 amp
    ) public view returns (uint256 y) {
        require(i != j, "same coin");

        uint256[3] memory xp = _xp(balances);

        uint256 D = _getD(xp, amp);
        uint256 Ann = amp * _N_COINS;

        uint256 c = D;
        uint256 S_;

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

    function getDy(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 amp
    ) public view returns (uint256 dy) {
        require(i != j, "same coin");
        require(i < _N_COINS && j < _N_COINS, "invalid index");

        uint256[3] memory xp = _xp(balances);

        uint256 x = xp[i];

        if (i == 0) {
            x += dx;
        } else {
            x += dx * _MULTIPLICATION_FACTOR;
        }

        uint256 y = getY(i, j, x, amp);

        uint256 dyNormalized = xp[j] - y;

        if (j == 0) {
            dy = dyNormalized;
        } else {
            dy = dyNormalized / _MULTIPLICATION_FACTOR;
        }

        return dy;
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 amp
    ) public returns (uint256) {
        require(i != j, "SAME CURRENCY");

        uint256 dy = getDy(i, j, dx, amp);

        balances[i] += dx;
        balances[j] -= dy;

        return dy;
    }

    function calculateAmountOut(
        uint256 amp,
        uint256 _totalSupply,
        uint256[3] memory amounts_,
        bool deposit
    ) public view returns (uint256 lpAmount) {
        uint256[3] memory oldBalances = balances;

        uint256 D0 = getD(oldBalances, amp);

        uint256[3] memory newBalances = oldBalances;

        for (uint256 i = 0; i < _N_COINS; i++) {
            if (deposit) {
                newBalances[i] += amounts_[i];
            } else {
                newBalances[i] -= amounts_[i];
            }
        }

        uint256 D1 = getD(newBalances, amp);

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

    function addLiquididty(
        uint256[3] memory amounts_,
        uint256 amp
    ) public returns (uint256) {
        uint256 lpMinted =
            calculateAmountOut(amp, totalSupply, amounts_, true);

        for (uint256 i = 0; i < _N_COINS; i++) {
            balances[i] += amounts_[i];
        }

        totalSupply += lpMinted;

        return lpMinted;
    }

    function removeLiquidity(
        uint256 lpAmount
    ) public returns (uint256[3] memory) {
        require(totalSupply > 0, "NO LIQUIDITY");

        uint256 share = (lpAmount * 1e18) / totalSupply;

        totalSupply -= lpAmount;

        for (uint256 i = 0; i < _N_COINS; i++) {
            amounts[i] = (balances[i] * share) / 1e18;
            balances[i] -= amounts[i];
        }

        return amounts;
    }

    function removeLiquidityOneCoin(
        uint256 lpAmount,
        uint256 i,
        uint256 amp
    ) external returns (uint256 dy) {
        require(i < _N_COINS, "invalid coin");
        require(totalSupply > 0, "no supply");

        uint256 share = (lpAmount * 1e18) / totalSupply;

        totalSupply -= lpAmount;

        uint256[3] memory xp = balances;
        uint256[3] memory newBalances;

        for (uint256 k = 0; k < _N_COINS; k++) {
            uint256 removed = (balances[k] * share) / 1e18;
            newBalances[k] = balances[k] - removed;
        }

        uint256 removedAmount = (balances[i] * share) / 1e18;

        dy = removedAmount;

        for (uint256 k = 0; k < _N_COINS; k++) {
            balances[k] = newBalances[k];
        }

        amp;
        xp;

        return dy;
    }
}