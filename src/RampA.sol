// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract RampA {
    uint256 public a_current;
    uint256 public a_target;
    uint256 public day0;
    uint256 public daytarget;

    constructor(uint256 _a_current, uint256 _a_target, uint256 _day0, uint256 _daytarget) {
        a_current = _a_current;
        a_target = _a_target;
        day0 = _day0;
        daytarget = _daytarget;
    }

    function getA() public view returns (uint256) {
        if (block.timestamp >= daytarget) {
            return a_target;
        }

        uint256 progress = ((block.timestamp - day0) * 1e18) / (daytarget - day0);

        uint256 A_new = a_current + ((a_target - a_current) * progress) / 1e18;

        return A_new;
    }
}
/* How far the transiition are we upto ?
 block.timestamp - T0 divided by T1-T0

 for Increasing A we need -> A new = A0+ (A1-A0)*progress
 for decreasing A we need -> A new = A0- (A1-A0)*progress

*/