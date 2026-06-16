// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract StableSwapMath {

    uint256 public constant _MULTIPLICATION_FACTOR = 1e12;

    uint256 public constant _MAX_ITERATIONS = 255;
    uint256 public constant _N_COINS = 3;
    uint256 public constant A=100;

    function _xp(
        uint256[3] memory balances
    ) public  pure returns (uint256[3] memory xp) {

        // DAI already has 18 decimals
        xp[0] = balances[0];

        // USDC and USDT have 6 decimals
         // 6 decimals -> 18 decimals

        xp[1] = balances[1] * _MULTIPLICATION_FACTOR;
        xp[2] = balances[2] * _MULTIPLICATION_FACTOR;

        return xp;
    }

    function getD(
        uint256[3] memory balances,
        uint256 A
    ) public pure returns (uint256 D) {
     // D is the total stable liquidity of the pool 
        uint256[3] memory xp = _xp(balances);

        uint256 S;
        for (uint256 i = 0; i < _N_COINS; i++) {
            S += xp[i];
        }
        if (S == 0) {
            return 0;
        }
        D = S;
        uint256 Ann = A * _N_COINS;
        for (uint256 i = 0; i < _MAX_ITERATIONS; i++) {
            // D_P= Product term 
            uint256 D_P = D;

            for (uint256 j = 0; j < _N_COINS; j++) {
                D_P = (D_P * D) / (xp[j] * _N_COINS);
            }
            // If pool is balanced then D_P=D=D(new);

            uint256 Dprev = D;

            D =
                ((Ann * S + D_P * _N_COINS) * D) /
                ((Ann - 1) * D + (_N_COINS + 1) * D_P);

            if (D > Dprev) {
                if (D - Dprev <= 1)// 1 wei  {
                    break;
                }
            else {
                if (Dprev - D <= 1) {
                    break;
                }
            }
                 return D;

        }
    }

    

    function get_virtual_price(uint256 lpSupply, uint256 _A, uint256[3] memory balances) public pure returns (uint256){
       uint256 _D = getD(balances,_A);
       uint256 virtualprice = (_D*1e18)/ lpSupply ;

       return virtualprice;
    }



    function getdY(uint256[3] memory balances, uint256 dx, uint256 whichtoken) returns (uint256){
        uint256 [3] memory xp= _xp(balances,A);
        for(uint256 i =0; i< xp[i];i++){
             if((i==whichtoken) && i!=0){
                xp[i]=xp[i]+ dx*_MULTIPLICATION_FACTOR;
             }
             if(i ==whichtoken && i ==0){
                  xp[i]=xp[i]+ dx;
             }
        }
        uint256 newY= getY();
        uint256 aproxamountOut= xp[whichtoken]-newY;
        return aproxamountOut;
    }
}

