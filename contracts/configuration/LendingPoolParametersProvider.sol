/*
 * @Description: 
 * @Author: Martin
 * @Date: 2023-02-20 16:34:09
 * @LastEditors: Martin
 * @LastEditTime: 2023-02-20 16:41:19
 */
//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;

contract LendingPoolParametersProvider {

    uint256 private constant MAX_STABLE_RATE_BORROW_SIZE_PERCENT = 25;
    uint256 private constant REBALANCE_DOWN_RATE_DELTA = (1e27)/5;

    function getMaxStableRateBorrowSizePercent() external pure returns (uint256) {
        return MAX_STABLE_RATE_BORROW_SIZE_PERCENT;
    }

    function getRebalanceDownRateDelta() external pure returns (uint256) {
        return REBALANCE_DOWN_RATE_DELTA;
    }  

}