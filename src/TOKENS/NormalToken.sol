// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract NormalToken {

    mapping(address => uint256) public balanceOf;

    constructor() {
        balanceOf[msg.sender] = 1_000_000e18;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Not enough balance");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {

        require(balanceOf[from] >= amount, "Not enough balance");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        return true;
    }
}