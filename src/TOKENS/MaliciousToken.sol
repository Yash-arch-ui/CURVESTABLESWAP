// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../StableSwapMath.sol";

contract MaliciousToken {

    StableSwapMath public pool;
    bool internal attacked;

    mapping(address => uint256) public balanceOf;

    constructor() {
        balanceOf[msg.sender] = 1_000_000e18;
    }

    function setPool(address _pool) external {
        pool = StableSwapMath(_pool);
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to,uint256 amount )external returns (bool)
    {
        require(balanceOf[msg.sender] >= amount, "Insufficient");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        return true;
    }

    function transferFrom( address from, address to, uint256 amount)
        external
        returns (bool)
    {
        require(balanceOf[from] >= amount, "Insufficient");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        // Re-enter only once
        if (!attacked) {
            attacked = true;

            pool.exchange(
                0,1,1e18,100
            );
        }

        return true;
    }
}