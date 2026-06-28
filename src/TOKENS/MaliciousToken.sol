// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../StableSwapMath.sol";

contract MaliciousToken {

    StableSwapMath public pool;
    bool internal attacked;
    enum AttackType {
        None,
        Exchange,
        AddLiquidity,
        RemoveLiquidity
    }

    AttackType public attackType;
    mapping(address => uint256) public balanceOf;
    constructor() {
        balanceOf[msg.sender] = 1_000_000e18;
    }

    function setPool(address _pool) external {
        pool = StableSwapMath(_pool);
    }

    function setAttackType(AttackType _type) external {
        attackType = _type;
    }
    function resetAttack() external {
        attacked = false;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount)
        external
        returns (bool)
    {
        require(balanceOf[msg.sender] >= amount, "Insufficient");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        // Uncomment this block ONLY if you want to test
        // removeLiquidity -> exchange/addLiquidity/removeLiquidity
        /*
        if (!attacked) {
            attacked = true;

            if (attackType == AttackType.Exchange) {
                pool.exchange(0, 1, 1e18, 100);
            }
            else if (attackType == AttackType.AddLiquidity) {
                uint256[3] memory amounts = [
                    uint256(1e18),
                    uint256(1e6),
                    uint256(1e6)
                ];

                pool.addLiquidity(amounts, 0);
            }
            else if (attackType == AttackType.RemoveLiquidity) {
                pool.removeLiquidity(1e18);
            }
        }
        */

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    )
        external
        returns (bool)
    {
        require(balanceOf[from] >= amount, "Insufficient");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        if (!attacked) {
            attacked = true;

            if (attackType == AttackType.None) {
                return true;
            }
            else if (attackType == AttackType.Exchange) {
                pool.exchange(0, 1, 1e18, 100);
            }
            else if (attackType == AttackType.AddLiquidity) {
                uint256[3] memory amounts = [
                    uint256(1e18),
                    uint256(1e6),
                    uint256(1e6)
                ];

                pool.addLiquidity(amounts, 0);
            }
            else if (attackType == AttackType.RemoveLiquidity) {
                pool.removeLiquidity(1e18);
            }

        }

        return true;
    }
}