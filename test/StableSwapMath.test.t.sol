// SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;
import {Test,console} from "forge-std/Test.sol";
import {StableSwapMath} from "../src/StableSwapMath.sol";
contract StableSwapMathTest is Test{
    StableSwapMath pool;
    uint256 public constant precision=1e12;
    uint256 public constant deposit_one=100e18;
    uint256 public constant deposit_two=100e6;
    function setUp() public {
      pool = new StableSwapMath();
    } 
    // _xp() tests
    function testDAIstaysunchanged() public {
        uint256[3] memory balances=[deposit_one,0,0];
        uint256[3] memory xp= pool._xp(balances);
        assertEq(xp[0],deposit_one);
    }
    function testUSDCscalingworks() public {
        uint256[3] memory balances=[0,deposit_two,0];
        uint256[3] memory xp=pool._xp(balances);
        assertEq(xp[1], deposit_two * precision);
    }
    function testScalingworks()  public {
        uint256[3] memory balances=[deposit_one,deposit_two,deposit_two];
        uint256[3] memory xp= pool._xp(balances);
        assertEq(xp[1], deposit_two * precision);
        assertEq(xp[2], deposit_two * precision);

    }
    // getD()  tests 
    function testgetDBalancedPool() public {
        uint256[3] memory balances=[deposit_one,deposit_two,deposit_two];
        uint256 D=pool.getD(balances,100);
        assertApproxEqRel(D,300e10,1e16);

    }
    function testgetDUnbalancedPool() public {
        uint256[3] memory balances=[2*deposit_one,deposit_two,deposit_two];
        uint256 D= pool.getD(balances,100);
        assertLt(D,400e18);

    }

    function testDwhenZeroLiq() public 
    {
        uint256[3] memory balances=[uint256(0),uint256(0),uint256(0)];
        uint256 D=pool.getD(balances,100);
        assertEq(D,0);
    }
    function testgetDextremeImbalancePool() public {
        uint256[3] memory balances=[uint256(1000e18),uint256(1e6),uint256(1e6)];
        uint256 D=pool.getD(balances,100);
        assertLt(D, 1000e18);
        // should be significantly lower than the raw sum 
    }
    function testgetDScalingInvariance() public {
        uint256[3] memory b1=[deposit_one,deposit_two,deposit_two];
        uint256[3] memory b2=[2*deposit_one,2*deposit_two,2*deposit_two];

        uint256 D1= pool.getD(b1,100);
        uint256 D2= pool.getD(b2,100);
        // Doubling balances should double D
        assertApproxEqRel(D2,D1*2,1e16);

    }
        function test_getD_deterministic() public {
        uint256[3] memory balances = [ uint256(123e18),uint256(456e6),uint256(789e6)];
        uint256 D1 = pool.getD(balances, 100);
        uint256 D2 = pool.getD(balances, 100);

        assertEq(D1, D2);
    }
}