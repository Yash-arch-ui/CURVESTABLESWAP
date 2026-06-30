//SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;
import "./StableSwapMath.sol";

contract LendingProtocol {
    StableSwapMath pool;
    uint256 public constant RATIO = 70;

    constructor(address _pool) {
        pool = StableSwapMath(_pool);
    }

    function borrow(uint256 lpAmount) public view returns (uint256) {
        uint256 perCoinPrice = pool.get_virtual_price(lpAmount, 100);
        return (perCoinPrice * lpAmount * 70) / 1e18 * 100;
    }
}
