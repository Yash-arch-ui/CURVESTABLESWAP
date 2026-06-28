// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {StableSwapMath} from "../src/StableSwapMath.sol";
import {MaliciousToken} from "../src/TOKENS/MaliciousToken.sol";
import {NormalToken} from "../src/TOKENS/NormalToken.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";

contract StableSwapMathTest is Test {
    StableSwapMath pool;
    StableSwapMath unBalancedpool;
    StableSwapMath highlyUnbalancedpool;
    LendingProtocol lendingprotocol;
    address attacker = makeAddr("attacker");
    
    uint256 public constant precision = 1e12;
    uint256 public constant deposit_one = 100e18;
    uint256 public constant deposit_two = 100e6;
    uint256 public constant A = 100; // amp constant
    MaliciousToken badToken;
    NormalToken usdc;
    NormalToken usdt;
    function setUp() public {
        // We must pass 3 dummy addresses to satisfy the new constructor
        badToken = new MaliciousToken();
        usdc = new NormalToken();
        usdt = new NormalToken();
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
        badToken.setAttackType(MaliciousToken.AttackType.Exchange);
        vm.expectRevert("Reentrancy detected");
        pool.exchange(0,1,10e18,A);
    }

    function testReentrancyOnAddLiquidity() public {
    badToken.setAttackType(MaliciousToken.AttackType.AddLiquidity);
    vm.expectRevert("Reentrancy detected");
    pool.addLiquidity([uint256(50e18), uint256(50e6), uint256(50e6)],A);
    }
    function testCrossfunctionReentrancy() public{
        badToken.setAttackType(MaliciousToken.AttackType.None);
        pool.addLiquidity([uint256(50e18),uint256(50e6),uint256(50e6)],A);
        badToken.resetAttack();
        badToken.setAttackType(MaliciousToken.AttackType.RemoveLiquidity);
        vm.expectRevert("Reentrancy detected");
        pool.exchange(0,1,10e18,A);
    }
    function testReadOnlyReentrancy() public{
// ALREADY WRITTEN CORRECT CODE FOR IT , SO NO NEED AS OF NOW 
    }
    function testFlashLoanAttack() public{
        vm.startPrank(attacker);
        badToken.setAttackType(MaliciousToken.AttackType.None);
        pool.addLiquidity([uint256(100e18),uint256(100e6),uint256(100e6)],A);
        badToken.mint(attacker, 1_000_000e18);
        uint256 aout = pool.exchange(0,1,1_000_000e18,A);
        // NOW THE ATTACKER CALLS THE PROTOCOL FOR THE EXCHANGING DAI(or some other) WITH THE LP
        uint256 aOutbyLendingProtocol = lendingprotocol.borrow(100e6);
        uint256 flashReceived = pool.exchange(1,0,aOutbyLendingProtocol);
        // REPAYED BY ATTACKER
        badToken.transfer(address(this), 1_000_000e18);
        vm.stopPrank();


        
    }
    
    
}