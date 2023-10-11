/*
 * @Description: 
 * @Author: Martin
 * @Date: 2023-02-20 11:01:57
 * @LastEditors: Martin
 * @LastEditTime: 2023-02-20 11:03:18
 */
//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;

interface IPriceOracleGetter {
    function getAssetPrice(address _asset) external view returns (uint256);
}