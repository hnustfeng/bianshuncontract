//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;

import "../interfaces/IReserveInterestRateStrategy.sol";
import "../libraries/WadRayMath.sol";
import "../configuration/LendingPoolAddressesProvider.sol";
import "./LendingPoolCore.sol";
import "../interfaces/ILendingRateOracle.sol";

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract DefaultReserveInterestRateStrategy is IReserveInterestRateStrategy {
    using WadRayMath for uint256;
    using SafeMath for uint256;

    /**
    * @dev this constant represents the utilization rate at which the pool aims to obtain most competitive borrow rates
    * expressed in ray
    **/
    uint256 public constant OPTIMAL_UTILIZATION_RATE = 0.8 * 1e27;

    /**
    * @dev this constant represents the excess utilization rate above the optimal. It's always equal to
    * 1-optimal utilization rate. Added as a constant here for gas optimizations
    * expressed in ray
    **/
    uint256 public constant EXCESS_UTILIZATION_RATE = 0.2 * 1e27;

    LendingPoolAddressesProvider public addressesProvider;

    //base variable borrow rate when Utilization rate = 0. Expressed in ray
    uint256 public baseVariableBorrowRate;

    //slope of the variable interest curve when utilization rate > 0 and <= OPTIMAL_UTILIZATION_RATE. Expressed in ray
    uint256 public variableRateSlope1;

    //slope of the variable interest curve when utilization rate > OPTIMAL_UTILIZATION_RATE. Expressed in ray
    uint256 public variableRateSlope2;

    //slope of the stable interest curve when utilization rate > 0 and <= OPTIMAL_UTILIZATION_RATE. Expressed in ray
    uint256 public stableRateSlope1;

    //slope of the stable interest curve when utilization rate > OPTIMAL_UTILIZATION_RATE. Expressed in ray
    uint256 public stableRateSlope2;

    address reserve;

    constructor(
        address _reserve,
        LendingPoolAddressesProvider _provider,
        uint256 _baseVariableBorrowRate,
        uint256 _variableRateSlope1,
        uint256 _variableRateSlope2,
        uint256 _stableRateSlope1,
        uint256 _stableRateSlope2
    ) {
        addressesProvider = _provider;
        baseVariableBorrowRate = _baseVariableBorrowRate;
        variableRateSlope1 = _variableRateSlope1;
        variableRateSlope2 = _variableRateSlope2;
        stableRateSlope1 = _stableRateSlope1;
        stableRateSlope2 = _stableRateSlope2;
        reserve = _reserve;
    }

    function getBaseVariableBorrowRate() external view returns (uint256) {
        return baseVariableBorrowRate;
    }

    function getVariableRateSlope1() external view returns (uint256) {
        return variableRateSlope1;
    }

    function getVariableRateSlope2() external view returns (uint256) {
        return variableRateSlope2;
    }

    function getStableRateSlope1() external view returns (uint256) {
        return stableRateSlope1;
    }

    function getStableRateSlope2() external view returns (uint256) {
        return stableRateSlope2;
    }

    function calculateInterestRates(
        address _reserve,
        uint256 _availableLiquidity,
        uint256 _totalBorrowsStable,
        uint256 _totalBorrowsVariable,
        uint256 _averageStableBorrowRate
    ) external view returns (
        uint256 currentLiquidityRate,
        uint256 currentStableBorrowRate,
        uint256 currentVariableBorrowRate
    ) {
        uint256 totalBorrows = _totalBorrowsStable.add(_totalBorrowsVariable);

        uint256 utilizationRate = (totalBorrows == 0 && _availableLiquidity == 0)
            ? 0
            : totalBorrows.rayDiv(_availableLiquidity.add(totalBorrows));
        
        currentStableBorrowRate = ILendingRateOracle(addressesProvider.getLendingRateOracle())
            .getMarketBorrowRate(_reserve);

        if(utilizationRate > OPTIMAL_UTILIZATION_RATE) {
            uint256 excessUtilizationRateRatio = utilizationRate
                .sub(OPTIMAL_UTILIZATION_RATE)
                .rayDiv(EXCESS_UTILIZATION_RATE);
            
            currentStableBorrowRate = currentStableBorrowRate
                .add(stableRateSlope1)
                .add(stableRateSlope2.rayMul(excessUtilizationRateRatio));
            
            currentVariableBorrowRate = baseVariableBorrowRate
                .add(variableRateSlope1)
                .add(variableRateSlope2.rayMul(excessUtilizationRateRatio));
        } else {
            currentStableBorrowRate = currentStableBorrowRate
                .add(stableRateSlope1
                        .rayMul(utilizationRate.rayDiv(
                            OPTIMAL_UTILIZATION_RATE
                        )));
            
            currentVariableBorrowRate = baseVariableBorrowRate.add(utilizationRate.rayDiv(OPTIMAL_UTILIZATION_RATE).rayMul(variableRateSlope1));
        }

        currentLiquidityRate = getOverallBorrowRateInternal(
            _totalBorrowsStable, 
            _totalBorrowsVariable, 
            currentVariableBorrowRate, 
            _averageStableBorrowRate
        ).rayMul(utilizationRate);
    }

    function getOverallBorrowRateInternal(
        uint256 _totalBorrowsStable,
        uint256 _totalBorrowsVariable,
        uint256 _currentVariableBorrowRate,
        uint256 _currentAverageStableBorrowRate
    ) internal pure returns (uint256) {
        uint256 totalBorrows = _totalBorrowsStable.add(_totalBorrowsVariable);

        if(totalBorrows == 0) return 0;

        uint256 weightedVariableRate = _totalBorrowsVariable.wadToRay().rayMul(_currentVariableBorrowRate);

        uint256 weightedStableRate = _totalBorrowsStable.wadToRay().rayMul(_currentAverageStableBorrowRate);

        uint256 overallBorrowRate = weightedVariableRate.add(weightedStableRate).rayDiv(totalBorrows.wadToRay());

        return overallBorrowRate;
    }
}