/*
 * @Description: 
 * @Author: Martin
 * @Date: 2023-02-17 16:40:36
 * @LastEditors: Martin
 * @LastEditTime: 2023-05-06 14:46:10
 */
//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;

import "../../interfaces/ILendingRateOracle.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LendingRateOracle is ILendingRateOracle, Ownable {

    mapping(address => uint256) borrowRates;
    mapping(address => uint256) liquidityRates;


    function getMarketBorrowRate(address _asset) external view returns(uint256) {
        return borrowRates[_asset];
    }

    function setMarketBorrowRate(address _asset, uint256 _rate) external onlyOwner {
        borrowRates[_asset] = _rate;
    }

    function getMarketLiquidityRate(address _asset) external view returns(uint256) {
        return liquidityRates[_asset];
    }

    function setMarketLiquidityRate(address _asset, uint256 _rate) external onlyOwner {
        liquidityRates[_asset] = _rate;
    }
}