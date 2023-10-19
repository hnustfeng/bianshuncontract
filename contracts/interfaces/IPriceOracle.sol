//SPDX-License-Identifier:MIT
pragma solidity ^0.8.9;

interface IPriceOracle {
    function getAssetPrice(address _asset) external view returns (uint256);

    function setAssetPrice(address _asset, uint256 _price) external;
}