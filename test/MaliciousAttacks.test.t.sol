// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {StableSwapMath} from "../src/StableSwapMath.sol";
import {MaliciousToken} from "../src/TOKENS/MaliciousToken.sol";
import {NormalToken} from "../src/TOKENS/NormalToken.sol";

contract StableSwapMathTest is Test {
    StableSwapMath pool;
    StableSwapMath unBalancedpool;
    StableSwapMath highlyUnbalancedpool;
    
    uint256 public constant precision = 1e12;
    uint256 public constant deposit_one = 100e18;
    uint256 public constant deposit_two = 100e6;
    uint256 public constant A = 100; // amp constant
     function setPool(address _pool) external {
        pool =StableSwapMath(_pool);
     }
    function setUp() public {
        // We must pass 3 dummy addresses to satisfy the new constructor
        MaliciousToken badToken = new MaliciousToken();
        NormalToken usdc = new NormalToken();
        NormalToken usdt = new NormalToken();
        address[3] memory tokens =[
            address(badToken), address(usdc),address(usdt)
        ];

        pool = new StableSwapMath([uint256(100e18), uint256(100e6), uint256(100e6)], tokens);
        unBalancedpool = new StableSwapMath([uint256(200e18), uint256(100e6), uint256(100e6)], tokens);
        highlyUnbalancedpool = new StableSwapMath([uint256(2000e18), uint256(100e6), uint256(100e6)], tokens);
        badToken.setPool(address(pool));
        badToken.mint(address(this), 1000e18);
        usdc.mint(address(this), 1000e18);
        usdt.mint(address(this), 1000e18);
    }

    function testMaliciousReentry() public  {
        vm.expectRevert("Reentrancy detected");
        pool.exchange(0,1,10e18,A);
    }

    function testReentrancyOnAddLiquidity() public {
    vm.expectRevert("Reentrancy detected");
    pool.addLiquidity([uint256(50e18), uint256(50e6), uint256(50e6)],A);
    }
     
    
}