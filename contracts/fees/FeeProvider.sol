//SPDX-License-Identifier:MIT
pragma solidity ^0.8.9;

import "../interfaces/IFeeProvider.sol";
import "../libraries/WadRayMath.sol";

contract FeeProvider is IFeeProvider {
    using WadRayMath for uint256;

    uint256 public originationFeePercentage;

    function initialize(address _addressesProvider) public {
        originationFeePercentage = 0.0025 * 10 ** 18;
    }

    function calculateLoanOriginationFee(address _user, uint256 _amount)
        external
        view 
        returns (uint256)
    {
        return _amount.wadMul(originationFeePercentage);
    }

    function getLoanOriginationFeePercentage() external view returns (uint256) {
        return originationFeePercentage;
    }
}