// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
interface IERC20{
        function transfer(address to, uint256 amount) external returns(bool);
        function transferFrom(address from , address to , uint256 amount) external returns(bool);
    }
contract StableSwapMath {
    uint256 public constant _MULTIPLICATION_FACTOR = 1e12;
    uint256 public constant _MAX_ITERATIONS = 255;
    uint256 public constant _N_COINS = 3;
    uint256 public constant DEFAULT_A = 100;
    uint256 public constant fee = 4_000_000; // 0.04%
    uint256 public constant FEE_DENOMINATOR = 10_000_000_000;

    bool private _locked;

    uint256[3] public balances;
    uint256 public totalSupply;
    uint256[3] public amounts;
    address[3] public coins;// Added array to track the actual ERC20 token addresses


    
    constructor(uint256[3] memory initialBalances,address[3] memory initialCoins) {
        balances = initialBalances;
        coins=initialCoins;
        totalSupply = 0;
    }

    // Fixed the modifier logic to correctly utilize the boolean flag
    modifier nonReentrant() {
        require(!_locked, "Reentrancy detected");
        _locked = true;
        _;
        _locked = false;
    }

    function _xp(uint256[3] memory _balances) public pure returns (uint256[3] memory xp) {
        xp[0] = _balances[0];
        xp[1] = _balances[1] * _MULTIPLICATION_FACTOR;
        xp[2] = _balances[2] * _MULTIPLICATION_FACTOR;
        return xp;
    }

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

    function _getD_balances(uint256[3] memory balances_, uint256 amp) internal pure returns (uint256) {
        uint256[3] memory xp = _xp(balances_);
        return _getD(xp, amp);
    }

    function _getY(uint256 i, uint256 j, uint256 x, uint256 amp) internal view returns (uint256 y) {
        require(i != j, "same coin");
        require(i < _N_COINS, "INVALID");
        require(j < _N_COINS, "INVALID");

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

    function _getDy(uint256 i, uint256 j, uint256 dx, uint256 amp) internal view returns (uint256 dy) {
        require(i != j, "same coin");
        require(i < _N_COINS && j < _N_COINS, "invalid index");

        uint256[3] memory xp = _xp(balances);
        uint256 x = xp[i];

        if (i == 0) {
            x += dx;
        } else {
            x += dx * _MULTIPLICATION_FACTOR;
        }

        uint256 y = _getY(i, j, x, amp);
        uint256 dyNormalized = xp[j] - y;

        if (j == 0) {
            dy = dyNormalized;
        } else {
            dy = dyNormalized / _MULTIPLICATION_FACTOR;
        }

        return dy;
    }

    function _calculateAmountOut(uint256 amp, uint256 _totalSupply, uint256[3] memory amounts_, bool deposit) internal view returns (uint256 lpAmount) {
        uint256[3] memory oldBalances = balances;
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
        for (uint256 k = 0; k < _MAX_ITERATIONS; k++) {
            uint256 yPrev = y;
            y = (y * y + c) / (2 * y + b - D);
            if (y > yPrev ? y - yPrev <= 1 : yPrev - y <= 1) break;
        }
        return y;
    }



    function getD(uint256[3] memory balances_, uint256 amp) external view returns (uint256) {
        return _getD_balances(balances_, amp);
    }

    function getY(uint256 i, uint256 j, uint256 x, uint256 amp) external view returns (uint256) {
        return _getY(i, j, x, amp);
    }

    function getDy(uint256 i, uint256 j, uint256 dx, uint256 amp) external view returns (uint256) {
        return _getDy(i, j, dx, amp);
    }

    function calculateAmountOut(uint256 amp, uint256 _totalSupply, uint256[3] memory amounts_, bool deposit) external view returns (uint256) {
        return _calculateAmountOut(amp, _totalSupply, amounts_, deposit);
    }



    function get_virtual_price(uint256 lpSupply, uint256 amp) external view returns (uint256) {
        require(lpSupply > 0 , "ZERO_SUPPLY");
        uint256 D = _getD_balances(balances, amp);
        return (D * 1e18) / lpSupply;
    }

    function exchange(uint256 i, uint256 j, uint256 dx, uint256 amp) public nonReentrant returns (uint256) {
        require(i != j, "SAME CURRENCY");
        require(i < _N_COINS && j < _N_COINS, "INVALID");
        //S1
        IERC20(coins[i]).transferFrom(msg.sender, address(this),dx);


        // Calls the internal version to bypass lock
        //S2
        uint256 dy = _getDy(i, j, dx, amp);
        uint256 dy_fee = dy * fee / FEE_DENOMINATOR;
        dy -= dy_fee;

        balances[i] += dx;
        balances[j] -= dy;
        IERC20(coins[j]).transfer(msg.sender,dy);

        return dy;
    }

    function addLiquidity(uint256[3] memory amounts_, uint256 amp) public nonReentrant returns (uint256) {
        // Calls the internal version to bypass lock
        uint256 lpMinted = _calculateAmountOut(amp, totalSupply, amounts_, true);
        
        for (uint256 i = 0; i < _N_COINS; i++) {
            IERC20(coins[i]).transferFrom(msg.sender, address(this), amounts_[i]);
            balances[i] += amounts_[i];
        }

        totalSupply += lpMinted;

        return lpMinted;
    }

    function removeLiquidity(uint256 lpAmount) public nonReentrant returns (uint256[3] memory) {
        require(totalSupply > 0, "NO LIQUIDITY");
        require(lpAmount <= totalSupply, "INSUFFICIENT_LP");
        uint256 share = (lpAmount * 1e18) / totalSupply;

        totalSupply -= lpAmount;

        for (uint256 i = 0; i < _N_COINS; i++) {
            amounts[i] = (balances[i] * share) / 1e18;
            balances[i] -= amounts[i];
            if(amounts[i] > 0){
                require( IERC20(coins[i]).transfer(msg.sender, amounts[i]), "Transfer failed");
            }
        }

        return amounts;
    }

    function removeLiquidityOneCoin(uint256 lpAmount, uint256 i, uint256 amp) external nonReentrant returns (uint256 dy) {
        require(i < _N_COINS, "invalid coin");
        require(totalSupply > 0, "no supply");
        require(lpAmount <= totalSupply, "INSUFFICIENT_LP");

        uint256 share = (lpAmount * 1e18) / totalSupply;
        totalSupply -= lpAmount;

        // Calls the internal version to bypass lock
        uint256 d0 = _getD_balances(balances, DEFAULT_A);
        
        uint256 d1 = (d0 * (1e18 - share)) / 1e18;
        uint256[3] memory normalizedBalances = _xp(balances);
        uint256 targetBalancerequired = _getYD(i, normalizedBalances, d1, DEFAULT_A);
        
        uint256 dyNormalized = normalizedBalances[i] - targetBalancerequired;
        
        if (i == 0) {
            dy = dyNormalized;
        } else {
            dy = dyNormalized / _MULTIPLICATION_FACTOR;
        }
        
        balances[i] -= dy;
        require(IERC20(coins[i]).transfer(msg.sender,dy) , "Transfer Failed ");
        return dy;
    }
}