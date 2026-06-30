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
    address victim = makeAddr("victim");
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
        address[3] memory tokens = [address(badToken), address(usdc), address(usdt)];
        pool = new StableSwapMath([uint256(100e18), uint256(100e6), uint256(100e6)], tokens);
        unBalancedpool = new StableSwapMath([uint256(200e18), uint256(100e6), uint256(100e6)], tokens);
        highlyUnbalancedpool = new StableSwapMath([uint256(2000e18), uint256(100e6), uint256(100e6)], tokens);
        badToken.setPool(address(pool));
        lendingprotocol = new LendingProtocol(address(pool));

        badToken.mint(address(pool), 100e18);
        usdc.mint(address(pool), 100e6);
        usdt.mint(address(pool), 100e16);
    }

    function testMaliciousReentry() public {
        badToken.setAttackType(MaliciousToken.AttackType.Exchange);
        vm.expectRevert("Reentrancy detected");
        pool.exchange(0, 1, 10e18, A);
    }

    function testReentrancyOnAddLiquidity() public {
        badToken.setAttackType(MaliciousToken.AttackType.AddLiquidity);
        vm.expectRevert("Reentrancy detected");
        pool.addLiquidity([uint256(50e18), uint256(50e6), uint256(50e6)], A);
    }

    function testCrossfunctionReentrancy() public {
        badToken.setAttackType(MaliciousToken.AttackType.None);
        pool.addLiquidity([uint256(50e18), uint256(50e6), uint256(50e6)], A);
        badToken.resetAttack();
        badToken.setAttackType(MaliciousToken.AttackType.RemoveLiquidity);
        vm.expectRevert("Reentrancy detected");
        pool.exchange(0, 1, 10e18, A);
    }
    function testReadOnlyReentrancy() public {
        // ALREADY WRITTEN CORRECT CODE FOR IT , SO NO NEED AS OF NOW
    }

    function testFlashLoanAttack() public {
        vm.startPrank(attacker);
        badToken.setAttackType(MaliciousToken.AttackType.None);
        badToken.mint(attacker, 100e18);
        usdc.mint(attacker, 100e6);
        usdt.mint(attacker, 100e6);
        pool.addLiquidity([uint256(100e18), uint256(100e6), uint256(100e6)], A);
        // CONSIDER THIS AS FLASH LOAN
        badToken.mint(attacker, 1_000_000e18);
        uint256 aout = pool.exchange(0, 1, 1_000_000e18, A);
        // NOW THE ATTACKER CALLS THE PROTOCOL FOR THE EXCHANGING DAI(or some other) WITH THE LP
        uint256 aOutbyLendingProtocol = lendingprotocol.borrow(100e6); // this is the profit .......
        uint256 rentedMoneyreceivedBack = pool.exchange(1, 0, aout, A);
        // REPAYED BY ATTACKER
        badToken.mint(attacker, 1_000_000e18);
        badToken.transfer(address(this), 1_000_000e18);
        console.log(aOutbyLendingProtocol);
        console.log(rentedMoneyreceivedBack);
        // here the bad token is not acting as bad becuase no execution enum attacks associated
        vm.stopPrank();
        // TO PREVENT FLASH LOANS TWAP WAS INTRODUCED IN LATER PART OF CURVE STABLESWAP VERSIONS.
    }

    function testSandwichAttack() public {
        badToken.setAttackType(MaliciousToken.AttackType.None);
        usdc.mint(victim, 50e6);
        usdc.mint(attacker, 100e6);
        // attacker knows some excahnge is going to take place obviously then he manipulates the pool.
        vm.startPrank(attacker);
        uint256 amountReceived = pool.exchange(1, 2, 100e6, A); // Pool manipulated properly
        console.log("AMOUNT RECEIVED BY ATTACKER AFTER DEPOSITING 100usdc:", amountReceived);
        vm.stopPrank();

        vm.startPrank(victim);
        uint256 amountRecbyVictim = pool.exchange(1, 2, 50e6, A);
        console.log("MONEY RECEIVED AFTER SANDWICH ATTACK:", amountRecbyVictim);
        vm.stopPrank();

        vm.startPrank(attacker);
        uint256 amountReceivedBackafterSandwich = pool.exchange(2, 1, amountReceived, A);
        if (amountReceivedBackafterSandwich > 100e6) {
            uint256 profitearned = amountReceivedBackafterSandwich - 100e6;
            console.log("NET ATTACKER PROFIT (USDC):", profitearned);
        } else {
            console.log("Attack executed, but did not clear initial principal costs.");
        }
        vm.stopPrank();
    }
}
