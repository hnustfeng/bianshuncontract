/*
 * @Description: 
 * @Author: Martin
 * @Date: 2023-02-20 11:06:14
 * @LastEditors: Martin
 * @LastEditTime: 2023-03-07 14:18:26
 */
//SPDX-License-Identifier:MIT
pragma solidity ^0.8.9;

import "../../interfaces/IPriceOracle.sol";

contract PriceOracle is IPriceOracle {
    mapping(address => uint256) prices;
    uint256 ethPriceUsd;

    event AssetPriceUpdated(address _asset, uint256 _price, uint256 timestamp);
    event EthPriceUpdated(uint256 _price, uint256 timestamp);

    function getAssetPrice(address _asset) external view returns (uint256) {
        return prices[_asset];
    }

    function setAssetPrice(address _asset, uint256 _price) external {
        prices[_asset] = _price;
        emit AssetPriceUpdated(_asset, _price, block.timestamp);
    }

    function getEthUsdPrice() external view returns(uint256) {
        return ethPriceUsd;
    }

    function setEthUsdPrice(uint256 _price) external {
        ethPriceUsd = _price;
        emit EthPriceUpdated(_price, block.timestamp);
    }
}