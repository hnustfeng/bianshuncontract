//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;

import "../../interfaces/IPriceOracleGetter.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract CLPriceOracle is IPriceOracleGetter, Ownable {
    mapping (address => address) oracles;

    event UpdateOracle(address indexed asset, address oracles);

    function setOracles(address asset, address oracle) public onlyOwner {
        oracles[asset] = oracle;
        emit UpdateOracle(asset, oracle);
    }

    function getAssetPrice(address _asset) public view returns(uint256) {
        if (_asset == address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE)) {
            return 10 ** 18;
        }

        AggregatorV3Interface priceFeed;
        address oracle = oracles[_asset];

        if(oracle != address(0)) {
            priceFeed = AggregatorV3Interface(oracle);
            (
                ,
                int256 answer,
                ,
                ,
                
                
            ) = priceFeed.latestRoundData();
            return uint256(answer);
        } else {
            return 0;
        }
    }
}