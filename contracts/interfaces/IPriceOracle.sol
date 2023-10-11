/*
 * @Description: 
 * @Author: Martin
 * @Date: 2023-02-20 11:08:34
 * @LastEditors: Martin
 * @LastEditTime: 2023-02-20 11:09:40
 */
//SPDX-License-Identifier:MIT
pragma solidity ^0.8.9;

interface IPriceOracle {
    function getAssetPrice(address _asset) external view returns (uint256);

    function setAssetPrice(address _asset, uint256 _price) external;
}