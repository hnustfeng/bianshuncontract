//SPDX-License-Identifier:MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./WadRayMath.sol";

library CoreLibrary {
    using SafeMath for uint256;
    using WadRayMath for uint256;

    enum InterestRateMode {NONE, STABLE, VARIABLE}

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    struct UserReserveData {
        //principal amount borrowed by the user.
        uint256 principalBorrowBalance;
        //cumulated variable borrow index for the user. Expressed in ray
        uint256 lastVariableBorrowCumulativeIndex;
        //origination fee cumulated by the user
        uint256 originationFee;
        // stable borrow rate at which the user has borrowed. Expressed in ray
        uint256 stableBorrowRate;
        uint40 lastUpdateTimestamp;
        //defines if a specific deposit should or not be used as a collateral in borrows
        bool useAsCollateral;
    }

    struct ReserveData {
        /**
        * @dev refer to the whitepaper, section 1.1 basic concepts for a formal description of these properties.
        **/
        //the liquidity index. Expressed in ray
        uint256 lastLiquidityCumulativeIndex;
        //the current supply rate. Expressed in ray
        uint256 currentLiquidityRate;
        //the total borrows of the reserve at a stable rate. Expressed in the currency decimals
        uint256 totalBorrowsStable;
        //the total borrows of the reserve at a variable rate. Expressed in the currency decimals
        uint256 totalBorrowsVariable;
        //the current variable borrow rate. Expressed in ray
        uint256 currentVariableBorrowRate;
        //the current stable borrow rate. Expressed in ray
        uint256 currentStableBorrowRate;
        //the current average stable borrow rate (weighted average of all the different stable rate loans). Expressed in ray
        uint256 currentAverageStableBorrowRate;
        //variable borrow index. Expressed in ray
        uint256 lastVariableBorrowCumulativeIndex;
        //the ltv of the reserve. Expressed in percentage (0-100)
        uint256 baseLTVasCollateral;
        //the liquidation threshold of the reserve. Expressed in percentage (0-100)
        uint256 liquidationThreshold;
        //the liquidation bonus of the reserve. Expressed in percentage
        uint256 liquidationBonus;
        //the decimals of the reserve asset
        uint256 decimals;
        /**
        * @dev address of the bToken representing the asset
        **/
        address bTokenAddress;
        /**
        * @dev address of the interest rate strategy contract
        **/
        address interestRateStrategyAddress;
        uint40 lastUpdateTimestamp;
        // borrowingEnabled = true means users can borrow from this reserve
        bool borrowingEnabled;
        // usageAsCollateralEnabled = true means users can use this reserve as collateral
        bool usageAsCollateralEnabled;
        // isStableBorrowRateEnabled = true means users can borrow at a stable rate
        bool isStableBorrowRateEnabled;
        // isActive = true means the reserve has been activated and properly configured
        bool isActive;
        // isFreezed = true means the reserve only allows repays and redeems, but not deposits, new borrowings or rate swap
        bool isFreezed;
    }

    function getNormalizedIncome(CoreLibrary.ReserveData storage _reserve) 
        internal
        view
        returns (uint256)
    {
        uint256 cumulated = calculateLinearInterest(
            _reserve.currentLiquidityRate,
            _reserve.lastUpdateTimestamp
        ).rayMul(_reserve.lastLiquidityCumulativeIndex);
        return cumulated;
    }

    function updateCumulativeIndexes(ReserveData storage _self) internal {
        uint256 totalBorrows = getTotalBorrows(_self);

        if(totalBorrows > 0) {
            uint256 cumulatedLiquidityInterest = calculateLinearInterest(
                _self.currentLiquidityRate,
                _self.lastUpdateTimestamp
            );

            _self.lastLiquidityCumulativeIndex = cumulatedLiquidityInterest.rayMul(
                _self.lastLiquidityCumulativeIndex
            );

            uint256 cumulatedVariableBorrowInterest = calculateCompoundedInterest(
                _self.currentVariableBorrowRate,
                _self.lastUpdateTimestamp
            );
            _self.lastVariableBorrowCumulativeIndex = cumulatedVariableBorrowInterest.rayMul(
                _self.lastVariableBorrowCumulativeIndex
            );
        }
    }

    function cumulateToLiquidityIndex(
        ReserveData storage _self,
        uint256 _totalLiquidity,
        uint256 _amount
    ) internal {
        uint256 amountToLiquidityRatio = _amount.wadToRay().rayDiv(_totalLiquidity.wadToRay());

        uint256 cumulatedLiquidity = amountToLiquidityRatio.add(WadRayMath.ray());

        _self.lastLiquidityCumulativeIndex = cumulatedLiquidity.rayMul(
            _self.lastLiquidityCumulativeIndex
        );
    }

    function init(
        ReserveData storage _self,
        address _bTokenAddress,
        uint256 _decimals,
        address _interestRateStrategyAddress
    ) external {
        require(_self.bTokenAddress == address(0), "Reserve has already been initialized!");

        if(_self.lastLiquidityCumulativeIndex == 0) {
            _self.lastLiquidityCumulativeIndex = WadRayMath.ray();
        }

        if(_self.lastVariableBorrowCumulativeIndex == 0) {
            _self.lastVariableBorrowCumulativeIndex = WadRayMath.ray();
        }

        _self.bTokenAddress = _bTokenAddress;
        _self.decimals = _decimals;

        _self.interestRateStrategyAddress = _interestRateStrategyAddress;
        _self.isActive = true;
        _self.isFreezed = false;
    }

    function enableBorrowing(ReserveData storage _self, bool _stableBorrowRateEnabled) external {
        require(_self.borrowingEnabled == false, "Reserve is already enabled!");

        _self.borrowingEnabled = true;
        _self.isStableBorrowRateEnabled = _stableBorrowRateEnabled;
    }

    function disableBorrowing(ReserveData storage _self) external {
        _self.borrowingEnabled = false;
    }

    function enableAsCollateral(
        ReserveData storage _self,
        uint256 _baseLTVasCollateral,
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus
    ) external {
        require(
            _self.usageAsCollateralEnabled == false,
            "Reserve is already enabled as collateral"
        );
        
        _self.usageAsCollateralEnabled = true;
        _self.baseLTVasCollateral = _baseLTVasCollateral;
        _self.liquidationThreshold = _liquidationThreshold;
        _self.liquidationBonus = _liquidationBonus;

        if(_self.lastLiquidityCumulativeIndex == 0) {
            _self.lastLiquidityCumulativeIndex = WadRayMath.ray();
        }
    }

    function disableAsCollateral(ReserveData storage _self) external {
        _self.usageAsCollateralEnabled = false;
    }

    function getCompoundedBorrowBalance(
        CoreLibrary.UserReserveData storage _self,
        CoreLibrary.ReserveData storage _reserve
    ) internal view returns (uint256) {
        if (_self.principalBorrowBalance == 0) {
            return 0;
        }

        uint256 principalBorrowBalanceRay = _self.principalBorrowBalance.wadToRay();
        uint256 compoundedBalance = 0;
        uint256 cumulatedInterest = 0;

        if(_self.stableBorrowRate > 0) {
            cumulatedInterest = calculateCompoundedInterest(
                _self.stableBorrowRate,
                _self.lastUpdateTimestamp
            );
        } else {
            cumulatedInterest = calculateCompoundedInterest(
                _reserve.currentVariableBorrowRate,
                _reserve.lastUpdateTimestamp
            )
            .rayMul(_reserve.lastVariableBorrowCumulativeIndex)
            .rayDiv(_self.lastVariableBorrowCumulativeIndex);
        }

        compoundedBalance = principalBorrowBalanceRay.rayMul(cumulatedInterest).rayToWad();

        if(compoundedBalance == _self.principalBorrowBalance) {
            if(_self.lastUpdateTimestamp != block.timestamp) {
                //no interest cumulation because of the rounding - we add 1 wei
                //as symbolic cumulated interest to avoid interest free loans.

                return _self.principalBorrowBalance.add(1 wei);
            }
        }

        return compoundedBalance;
    }

    function increaseTotalBorrowsStableAndUpdateAverageRate(
        ReserveData storage _reserve,
        uint256 _amount,
        uint256 _rate
    ) internal {
        uint256 previousTotalBorrowStable = _reserve.totalBorrowsStable;

        _reserve.totalBorrowsStable = _reserve.totalBorrowsStable.add(_amount);

        uint256 weightedLastBorrow = _amount.wadToRay().rayMul(_rate);
        uint256 weightedPreviousTotalBorrows = previousTotalBorrowStable.wadToRay().rayMul(
            _reserve.currentAverageStableBorrowRate
        );

        _reserve.currentAverageStableBorrowRate = weightedLastBorrow
            .add(weightedPreviousTotalBorrows)
            .rayDiv(_reserve.totalBorrowsStable.wadToRay());
    }

    function decreaseTotalBorrowsStableAndUpdateAverageRate(
        ReserveData storage _reserve,
        uint256 _amount,
        uint256 _rate
    ) internal {
        require(_reserve.totalBorrowsStable >= _amount, "Invalid amount to decrease");

        uint256 previousTotalBorrowStable = _reserve.totalBorrowsStable;

        _reserve.totalBorrowsStable = _reserve.totalBorrowsStable.sub(_amount);

        if(_reserve.totalBorrowsStable == 0) {
            _reserve.currentAverageStableBorrowRate = 0;
            return;
        }

        uint256 weightedLastBorrow = _amount.wadToRay().rayMul(_rate);
        uint256 weightedPreviousTotalBorrows = previousTotalBorrowStable.wadToRay().rayMul(
            _reserve.currentAverageStableBorrowRate
        );

        require(
            weightedPreviousTotalBorrows >= weightedLastBorrow,
            "The amount to subtract don't match!"
        );

        _reserve.currentAverageStableBorrowRate = weightedPreviousTotalBorrows
            .sub(weightedLastBorrow)
            .rayDiv(_reserve.totalBorrowsStable.wadToRay());
    }

    function increaseTotalBorrowsVariable(ReserveData storage _reserve, uint256 _amount) internal {
        _reserve.totalBorrowsVariable = _reserve.totalBorrowsVariable.add(_amount);
    }

    function decreaseTotalBorrowsVariable(ReserveData storage _reserve, uint256 _amount) internal {
        require(
            _reserve.totalBorrowsVariable >= _amount,
            "The amount that is being subtracted from the variable total borrows is incorrect!"
        );
        _reserve.totalBorrowsVariable = _reserve.totalBorrowsVariable.sub(_amount);
    }

    function calculateLinearInterest(uint256 _rate, uint40 _lastUpdateTimestamp)
        internal
        view
        returns (uint256)
    {
        uint256 timeDifference = block.timestamp.sub(uint256(_lastUpdateTimestamp));
        
        uint256 timeDelta = timeDifference.wadToRay().rayDiv(SECONDS_PER_YEAR.wadToRay());
        
        return _rate.rayMul(timeDelta).add(WadRayMath.ray());
    }

    function calculateCompoundedInterest(uint256 _rate, uint40 _lastUpdateTimestamp)
        internal
        view
        returns (uint256)
    {
        uint256 timeDifference = block.timestamp.sub(uint256(_lastUpdateTimestamp));
        
        uint256 ratePerSecond = _rate.div(SECONDS_PER_YEAR);

        return (ratePerSecond.add(WadRayMath.ray())).rayPow(timeDifference);
    }

    function getTotalBorrows(CoreLibrary.ReserveData storage _reserve)
        internal
        view
        returns (uint256)
    {
        return _reserve.totalBorrowsStable.add(_reserve.totalBorrowsVariable);
    }
}