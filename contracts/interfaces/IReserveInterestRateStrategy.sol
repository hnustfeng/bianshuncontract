pragma solidity ^0.8.9;

interface IReserveInterestRateStrategy {
    function getBaseVariableBorrowRate() external view returns (uint256);

    function calculateInterestRates(
        address _reserve,
        uint256 _availableLiquidity,//@note: _utilizationRate
        uint256 _totalBorrowsStable,
        uint256 _totalBorrowsVariable,
        uint256 _averageStableBorrowRate
    ) external view returns (
        uint256 currentLiquidityRate,//@note: liquidityRate
        uint256 currentStableBorrowRate,//@note: stableBorrowRate
        uint256 currentVariableBorrowRate//@note: variableBorrowRate
    );

}