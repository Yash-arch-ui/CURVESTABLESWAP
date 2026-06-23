// SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;
import {Test, console} from "forge-std/Test.sol";
import {StableSwapMath} from "../src/StableSwapMath.sol";

contract StableSwapMathTest is Test {
    StableSwapMath pool;
    StableSwapMath unBalancedpool;
    StableSwapMath highlyUnbalancedpool;
    uint256 public constant precision = 1e12;
    uint256 public constant deposit_one = 100e18;
    uint256 public constant deposit_two = 100e6;
    uint256 public constant A = 100; // amp constant

    function setUp() public {
        pool = new StableSwapMath([uint256(100e18), uint256(100e6), uint256(100e6)]);
        unBalancedpool = new StableSwapMath([uint256(200e18), uint256(100e6), uint256(100e6)]);
        highlyUnbalancedpool= new StableSwapMath([uint256(2000e18), uint256(100e6), uint256(100e6)]);
        }

    // _xp() tests
    function testDAIstaysunchanged() public view {
        uint256[3] memory balances = [deposit_one, 0, 0];
        uint256[3] memory xp = pool._xp(balances);
        assertEq(xp[0], deposit_one);
    }

    function testUSDCscalingworks() public view {
        uint256[3] memory balances = [0, deposit_two, 0];
        uint256[3] memory xp = pool._xp(balances);
        assertEq(xp[1], deposit_two * precision);
    }

    function testScalingworks() public view {
        uint256[3] memory balances = [deposit_one, deposit_two, deposit_two];
        uint256[3] memory xp = pool._xp(balances);
        assertEq(xp[1], deposit_two * precision);
        assertEq(xp[2], deposit_two * precision);
    }

    // getD()  tests
    function testgetDBalancedPool() public view {
        uint256[3] memory balances = [deposit_one, deposit_two, deposit_two];
        uint256 D = pool.getD(balances, A);
        assertEq(D, 300 ether);
    }

    function testgetDUnbalancedPool() public view {
        uint256[3] memory balances = [2 * deposit_one, deposit_two, deposit_two];
        uint256 D = pool.getD(balances, A);
        assertLt(D, 400e18);
    }

    function testDwhenZeroLiq() public view {
        uint256[3] memory balances = [uint256(0), uint256(0), uint256(0)];
        uint256 D = pool.getD(balances, A);
        assertEq(D, 0);
    }

    function testgetDextremeImbalancePool() public view {
        uint256[3] memory balances = [uint256(1000e18), uint256(1e6), uint256(1e6)];
        uint256 D = pool.getD(balances, A);
        assertLt(D, 1000e18);
        // should be significantly lower than the raw sum
    }

    function testgetDScalingInvariance() public view {
        uint256[3] memory b1 = [deposit_one, deposit_two, deposit_two];
        uint256[3] memory b2 = [2 * deposit_one, 2 * deposit_two, 2 * deposit_two];

        uint256 D1 = pool.getD(b1, A);
        uint256 D2 = pool.getD(b2, A);
        // Doubling balances should double D
        assertApproxEqRel(D2, D1 * 2, 1e16);
    }

    function test_getD_deterministic() public view {
        uint256[3] memory balances = [uint256(123e18), uint256(456e6), uint256(789e6)];
        uint256 D1 = pool.getD(balances, A);
        uint256 D2 = pool.getD(balances, A);

        assertEq(D1, D2);
    }

    // get y tests
    function testGetYReturnsValue() public view {
        uint256 y = pool.getY(0, 1, 110 ether, A);
        assertGt(y, 0);
        console.log(y);
    }

    function testGetYRevertSameCoin() public {
        vm.expectRevert("same coin");
        pool.getY(0, 0, 110 ether, A);
    }

    function testgetGetYExecutesandtoken1decreases() public view {
        uint256 y = pool.getY(0, 1, 110 ether, A);
        assertLt(y, 100 ether);
        console.log(y);
    }

    function testLargerswapviaGetyfxn() public view {
        uint256 y = pool.getY(0, 1, 150 ether, A);
        assertLt(y, 70 ether);
        console.log(y);
    }
    // COMMON SENSE - LOGIC MATHS:
    /*
      10 DAI Swap -> y ~ 90
      50 DAI Swap -> y ~ 50-60
    */

    function testDifferentSwapviagetY() public view {
        uint256 y1 = pool.getY(0, 1, 110 ether, A * 2);
        uint256 y2 = pool.getY(0, 1, 120 ether, A * 2);
        uint256 y3 = pool.getY(0, 1, 125 ether, A * 2);
        console.log(y1);
        console.log(y2);
        console.log(y3);
        assertGt(y1, y2);
        assertGt(y2, y3);
    }

    function testHowAaffectsgetY() public view {
        uint256 y1 = pool.getY(0, 1, 110 ether, A);
        uint256 y2 = pool.getY(0, 1, 120 ether, A);
        uint256 y3 = pool.getY(0, 1, 125 ether, A);
        console.log(y1);
        console.log(y2);
        console.log(y3);
        assertGt(y1, y2);
        assertGt(y2, y3);
        console.log("Changing A changes the values of y1,y2,y2 obviously because the formula depends on it ");
    }
    function testadditionviagetYUnbalancedPool() public view {
        uint256 y = unBalancedpool.getY(0,1,400 ether,A);
        console.log(y);
        assertGt(y,0);
    }
    function testgetYHighlyUnbalancedPool() public view {
        uint256 y = highlyUnbalancedpool.getY(0,1,200 ether, A);
        console.log(y);
        assertGt(y,0);
        //1846.088627766239577034e18 =y i.e.token0 drops from 2000 to 200 token1 must increase from 100 to 1846

    }
    function testadditioninHighlyUnbalancedPool() public view {
        uint256 y = highlyUnbalancedpool.getY(0,1,2200 ether,A);
        assertGt(y,0);
        console.log(y);
        assertLt(y,100 ether);
    }
    
}