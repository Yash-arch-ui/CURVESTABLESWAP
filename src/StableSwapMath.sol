// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract StableSwapMath {

    uint256 public constant _MULTIPLICATION_FACTOR = 1e12;
    uint256 public constant _MAX_ITERATIONS = 255;
    uint256 public constant _N_COINS = 3;
    uint256 public constant DEFAULT_A = 100;
    uint256[3] public  balances;
    uint256 public totalSupply;
    uint256[3] public amounts;
    
    constructor(uint256[3] memory initialBalances){
        balances = initialBalances;
        totalSupply=0;
    }
    function _xp() public view returns (uint256[3] memory xp) {
        xp[0] = balances[0];
        xp[1] = balances[1] * _MULTIPLICATION_FACTOR;
        xp[2] = balances[2] * _MULTIPLICATION_FACTOR;

        return xp;
    }

    function _getD( uint256[3] memory xp, uint256 amp ) public  view returns (uint256 D) {

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
            D =((Ann * S + D_P * _N_COINS) * D) /((Ann - 1) * D + (_N_COINS + 1) * D_P);
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

    function getD( uint256 amp ) public view returns (uint256) {

        (uint256[3] memory xp) = _xp();
        return _getD(xp, amp);
    }

    function get_virtual_price(
        uint256 lpSupply,
        uint256 amp
    ) public view returns (uint256) {

        uint256 D = getD(balances, amp);

        return (D * 1e18) / lpSupply;
    }

    function getY( uint256 i, uint256 j, uint256 x, uint256 amp
    ) public view returns (uint256 y) {
       // getY(i=0,j=1,x=110,xp) where xp=[100,100,100]
        require(i != j, "same coin");
        (uint256[3] memory xp) = _xp(balances);
        uint256 D = _getD(xp, amp);
        uint256 Ann = amp * _N_COINS;
        uint256 c = D;
        uint256 S_;
        for (uint256 idx = 0; idx < _N_COINS; idx++) {
            uint256 currentX;
            if (idx == i) {
                currentX = x;
                // current x= new x=110
            } else if (idx == j) {
                continue;
            } else {
                currentX = xp[idx];
            }
            S_ += currentX; 
            c = (c * D) / (currentX * _N_COINS);
        }

        c = (c * D) / (Ann * _N_COINS);  // Final c adjustment .

        uint256 b = S_ + (D / Ann);
        y = D;
        for (uint256 k = 0; k < _MAX_ITERATIONS; k++) {
            uint256 yPrev = y;
            y =(y * y + c) /((2 * y) + b - D);

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
      function getDy( uint256 i, uint256 j, uint256 dx,uint256 amp
) public view returns (uint256 dy) {
    require(i != j, "same coin");
    require(i < _N_COINS && j < _N_COINS, "invalid index");

   ( uint256[3] memory xp) = _xp(balances);
    uint256 x = xp[i];
    if (i == 0) {
        // DAI (18 decimals)
        x += dx;
    } else {
        // USDC / USDT (6 decimals -> normalize)
        x += dx * _MULTIPLICATION_FACTOR;
    }
    uint256 y = getY(
        i, j, x,balances,amp
    );

    // Amount removed from token-out side
    uint256 dyNormalized = xp[j] - y;

    // Convert back from normalized units
    if (j == 0) {
        dy = dyNormalized;
    } else {
        dy = dyNormalized / _MULTIPLICATION_FACTOR;
    }

    // Optional fee
    // uint256 fee = (dy * SWAP_FEE) / FEE_DENOMINATOR;
    // dy -= fee;

    return dy;
}

function exchange(uint256 i, uint256 j , uint256 dx, uint256 amp)public view returns(uint256){
    require(i != j, "SAME CURRENCY");
    uint256 dy =getDy(i,j,dx,balances,amp);
   balances[i] += dx; 
    balances[j] -=dy;
    return dy ;
}

function calculateAmountOut(uint256 amp , uint256 _totalSupply, uint256[3] memory amounts, bool deposit) public view returns(uint256){
    totalSupply = _totalSupply;
     uint256[3] memory oldBalances= balances;
     uint256 D0 = getD(oldBalances, amp);
     uint256[3] memory newBalances = oldBalances;
        for (uint256 i = 0; i < _N_COINS; i++) {
        if (deposit) {
            newBalances[i] += amounts[i];
        } else {
            newBalances[i] -= amounts[i];
        }
    }
    uint256 D1 = getD(newBalances, amp);
    if(totalSupply == 0){return D1;
    }
    if(deposit){
         uint256 lpAmount =(( D1-D0) *totalSupply)/D0;
    }else{
        uint256 lpAmount = ((D0 - D1) * totalSupply) / D0;
    }
    return lpAmount;
    _totalSupply = totalSupply;
    /* DAI  = 100
       USDC = 100
       USDT = 100


       Suppose-D0 = 300,LP Supply = 300
       User deposits:10 DAI,10 USDC,10 USDT
       New balances:110,110,110

       New liquidity
       D1 = 330
       LP minted

        (D1 - D0) * supply / D0 = (330 - 300) * 300 / 300 = 30 , which user gets as LP Tokens 
        LP Ownership is proportional 



    */
}

function addLiquididty( uint256[3] memory amounts, uint256 amp) public view returns (uint256){
    uint256 lpMinted= calculateAmountOut(amp,totalSupply,amounts,true);
        for (uint256 i = 0; i < _N_COINS; i++) {
        balances[i] += amounts[i];
    }
    totalSupply += lpMinted;
    return lpMinted;

}

function removeLiquidity(uint256 lpAmount) public  returns(uint256){
    require(totalSupply >0 , "NO LIquidity");
    uint256 share = (lpAmount * 1e18)/ totalSupply;
    totalSupply -= lpAmount;
    for(uint256 i =0 ; i< _N_COINS;i++){
        amounts[i] = (balances [i]*share) / 1e18;
        balances[i] -= amounts[i];
    }
    return amounts;
}
function removeLiquidityOneCoin( uint256 lpAmount, uint256 i, uint256 amp) external returns (uint256 dy) {

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
    uint256 D = getD(xp, amp);
    uint256 x = newBalances[i];

    uint256 y = getY( i, i, x,  newBalances,amp
    );
    dy = xp[i] - y;

    for (uint256 k = 0; k < _N_COINS; k++) {
        balances[k] = newBalances[k];
    }

    return dy;
}
}