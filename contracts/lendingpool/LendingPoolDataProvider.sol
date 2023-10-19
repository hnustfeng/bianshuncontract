//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../proxys/InitializableWithSlot.sol";

import "../libraries/CoreLibrary.sol";
import "../libraries/WadRayMath.sol";
import "../configuration/LendingPoolAddressesProvider.sol";
import "../interfaces/IPriceOracleGetter.sol";
import "../interfaces/IFeeProvider.sol";
import "../tokenization/BToken.sol";

import "./LendingPoolCore.sol";

contract LendingPoolDataProvider is InitializableWithSlot {
    using SafeMath for uint256;
    using WadRayMath for uint256;

    LendingPoolCore public core;
    LendingPoolAddressesProvider public addressesProvider;

    uint256 public constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18;
    
    function initialize(LendingPoolAddressesProvider _addressesProvider) public initializer {
        addressesProvider = _addressesProvider;
        core = LendingPoolCore(payable(_addressesProvider.getLendingPoolCore()));
    }

    struct UserGlobalDataLocalVars {
        uint256 reserveUnitPrice;
        uint256 tokenUnit;
        uint256 compoundedLiquidityBalance;
        uint256 compoundedBorrowBalance;
        uint256 reserveDecimals;
        uint256 baseLtv;
        uint256 liquidationThreshold;
        uint256 originationFee;
        bool usageAsCollateralEnabled;
        bool userUsesReserveAsCollateral;
        address currentReserve;
    }

    function calculateUserGlobalData(address _user)
        public 
        view
        returns (
            uint256 totalLiquidityBalanceETH,
            uint256 totalCollateralBalanceETH,
            uint256 totalBorrowBalanceETH,
            uint256 totalFeesETH,
            uint256 currentLtv,
            uint256 currentLiquidationThreshold,
            uint256 healthFactor,
            bool healthFactorBelowThreshold
        )
    {
        IPriceOracleGetter oracle = IPriceOracleGetter(addressesProvider.getPriceOracle());

        UserGlobalDataLocalVars memory vars;

        address[] memory reserves = core.getReserves();

        for (uint256 i = 0; i < reserves.length; i++) {
            vars.currentReserve = reserves[i];

            (
                vars.compoundedLiquidityBalance,
                vars.compoundedBorrowBalance,
                vars.originationFee,
                vars.userUsesReserveAsCollateral
            ) = core.getUserBasicReserveData(vars.currentReserve, _user);

            if(vars.compoundedLiquidityBalance == 0 && vars.compoundedBorrowBalance == 0) {
                continue;
            }

            (
                vars.reserveDecimals,
                vars.baseLtv,
                vars.liquidationThreshold,
                vars.usageAsCollateralEnabled
            ) = core.getReserveConfiguration(vars.currentReserve);

            vars.tokenUnit = 10 ** vars.reserveDecimals;
            vars.reserveUnitPrice = oracle.getAssetPrice(vars.currentReserve);

            //liquidity and collateral balance
            if(vars.compoundedLiquidityBalance > 0) {
                uint256 liquidityBalanceETH = vars.reserveUnitPrice.mul(vars.compoundedLiquidityBalance).div(vars.tokenUnit);
                totalLiquidityBalanceETH = totalLiquidityBalanceETH.add(liquidityBalanceETH);

                if(vars.usageAsCollateralEnabled && vars.userUsesReserveAsCollateral) {
                    totalCollateralBalanceETH = totalCollateralBalanceETH.add(liquidityBalanceETH);
                    currentLtv = currentLtv.add(liquidityBalanceETH.mul(vars.baseLtv));
                    currentLiquidationThreshold = currentLiquidationThreshold.add(liquidityBalanceETH.mul(vars.liquidationThreshold));
                }
            }

            if(vars.compoundedBorrowBalance > 0) {
                totalBorrowBalanceETH = totalBorrowBalanceETH.add(vars.reserveUnitPrice.mul(vars.compoundedBorrowBalance).div(vars.tokenUnit));
                totalFeesETH = totalFeesETH.add(vars.originationFee.mul(vars.reserveUnitPrice).div(vars.tokenUnit));
            }
        }

        currentLtv = totalCollateralBalanceETH > 0 ? currentLtv.div(totalCollateralBalanceETH) : 0;
        currentLiquidationThreshold = totalCollateralBalanceETH > 0
            ? currentLiquidationThreshold.div(totalCollateralBalanceETH)
            : 0;
        
        healthFactor = calculateHealthFactorFromBalancesInternal(
            totalCollateralBalanceETH,
            totalBorrowBalanceETH,
            totalFeesETH,
            currentLiquidationThreshold
        );
        healthFactorBelowThreshold = healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD;
    }

    struct balanceDecreaseAllowedLocalVars {
        uint256 decimals;
        uint256 collateralBalanceETH;
        uint256 borrowBalanceETH;
        uint256 totalFeesETH;
        uint256 currentLiquidationThreshold;
        uint256 reserveLiquidationThreshold;
        uint256 amountToDecreaseETH;
        uint256 collateralBalanceAfterDecrease;
        uint256 liquidationThresholdAfterDecrease;
        uint256 healthFactorAfterDecrease;
        bool reserveUsageAsCollateralEnabled;
    }

    function balanceDecreaseAllowed(address _reserve, address _user, uint256 _amount)
        external
        view 
        returns (bool)
    {
        balanceDecreaseAllowedLocalVars memory vars;

        (
            vars.decimals,
            ,
            vars.reserveLiquidationThreshold,
            vars.reserveUsageAsCollateralEnabled
        ) = core.getReserveConfiguration(_reserve);

        if (!vars.reserveUsageAsCollateralEnabled || !core.isUserUseReserveAsCollateralEnabled(_reserve, _user)) {
            return true; //if reserve is not used to collateral, no reasons to block the transfer
        }

        (
            ,
            vars.collateralBalanceETH,
            vars.borrowBalanceETH,
            vars.totalFeesETH,
            ,
            vars.currentLiquidationThreshold,
            ,
        ) = calculateUserGlobalData(_user);

        if(vars.borrowBalanceETH == 0) {
            return true; //no borrows - no reasons to block the transfer
        }

        IPriceOracleGetter oracle = IPriceOracleGetter(addressesProvider.getPriceOracle());

        vars.amountToDecreaseETH = oracle.getAssetPrice(_reserve).mul(_amount).div(10 ** vars.decimals);

        vars.collateralBalanceAfterDecrease = vars.collateralBalanceETH.sub(vars.amountToDecreaseETH);

        //if there is a borrow, there can't be 0 collateral
        if(vars.collateralBalanceAfterDecrease == 0) {
            return false;
        }

        vars.liquidationThresholdAfterDecrease = vars
            .collateralBalanceETH
            .mul(vars.currentLiquidationThreshold)
            .sub(vars.amountToDecreaseETH.mul(vars.reserveLiquidationThreshold))
            .div(vars.collateralBalanceAfterDecrease);

        uint256 healthFactorAfterDecrease = calculateHealthFactorFromBalancesInternal(
            vars.collateralBalanceAfterDecrease,
            vars.borrowBalanceETH,
            vars.totalFeesETH,
            vars.liquidationThresholdAfterDecrease
        );

        return healthFactorAfterDecrease > HEALTH_FACTOR_LIQUIDATION_THRESHOLD;
    }

    function calculateCollateralNeededInETH(
        address _reserve,
        uint256 _amount,
        uint256 _fee,
        uint256 _userCurrentBorrowBalanceTH,
        uint256 _userCurrentFeesETH,
        uint256 _userCurrentLtv
    ) external view returns (uint256) {
        uint256 reserveDecimals = core.getReserveDecimals(_reserve);
        IPriceOracleGetter oracle = IPriceOracleGetter(addressesProvider.getPriceOracle());

        uint256 requrestedBorrowAmountETH = oracle
            .getAssetPrice(_reserve)
            .mul(_amount.add(_fee))
            .div(10 ** reserveDecimals); // price in ether

        uint256 collateralNeededInETH = _userCurrentBorrowBalanceTH
            .add(_userCurrentFeesETH)
            .add(requrestedBorrowAmountETH)
            .mul(100)
            .div(_userCurrentLtv);

        return collateralNeededInETH;
    }



    //@notice: internal functions

    function calculateAvailableBorrowsETHInternal(
        uint256 collateralBalanceETH,
        uint256 borrowBalanceETH,
        uint256 totalFeesETH,
        uint256 ltv
    ) internal view returns (uint256) {
        uint256 availableBorrowsETH = collateralBalanceETH.mul(ltv).div(100); //ltv is in percentage

        if(availableBorrowsETH < borrowBalanceETH) {
            return 0;
        }

        availableBorrowsETH = availableBorrowsETH.sub(borrowBalanceETH.add(totalFeesETH));
        //calculate fee
        uint256 borrowFee = IFeeProvider(addressesProvider.getFeeProvider())
            .calculateLoanOriginationFee(msg.sender, availableBorrowsETH);
        return availableBorrowsETH.sub(borrowFee);
    }

    function calculateHealthFactorFromBalancesInternal(
        uint256 collateralBalanceETH,
        uint256 borrowBalanceETH,
        uint256 totalFeesETH,
        uint256 liquidationThreshold
    ) internal pure returns (uint256) {
        if(borrowBalanceETH == 0) {
            return type(uint256).max;
        }

        return (collateralBalanceETH.mul(liquidationThreshold).div(100)).wadDiv(borrowBalanceETH.add(totalFeesETH));
    }

    function getHealthFactorLiquidationThreshold() public pure returns (uint256) {
        return HEALTH_FACTOR_LIQUIDATION_THRESHOLD;
    }

    function getReserveConfigurationData(address _reserve)
        external
        view
        returns (
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            address rateStrategyAddress,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive
        )
    {
        (, ltv, liquidationThreshold, usageAsCollateralEnabled) = core.getReserveConfiguration(
            _reserve
        );
        stableBorrowRateEnabled = core.getReserveIsStableBorrowRateEnabled(_reserve);
        borrowingEnabled = core.isReserveBorrowingEnabled(_reserve);
        isActive = core.getReserveIsActive(_reserve);
        liquidationBonus = core.getReserveLiquidationBonus(_reserve);

        rateStrategyAddress = core.getReserveInterestRateStrategyAddress(_reserve);
    }

    struct Reserve {
        uint256 totalLiquidity;
        uint256 availableLiquidity;
        uint256 totalBorrowsStable;
        uint256 totalBorrowsVariable;
        uint256 liquidityRate;
        uint256 variableBorrowRate;
        uint256 stableBorrowRate;
        uint256 averageStableBorrowRate;
        uint256 utilizationRate;
        uint256 liquidityIndex;
        uint256 variableBorrowIndex;
        address bTokenAddress;
        uint40 lastUpdateTimestamp;
    }

    function getReserveData(address _reserve)
        external 
        view 
        returns (
            Reserve memory
        )
    {
        // return core.getReserveData(_reserve);
        Reserve memory data;
        data.totalLiquidity = core.getReserveTotalLiquidity(_reserve);
        data.availableLiquidity = core.getReserveAvailableLiquidity(_reserve);
        data.totalBorrowsStable = core.getReserveTotalBorrowsStable(_reserve);
        data.totalBorrowsVariable = core.getReserveTotalBorrowsVariable(_reserve);
        data.liquidityRate = core.getReserveCurrentLiquidityRate(_reserve);
        data.variableBorrowRate = core.getReserveCurrentVariableBorrowRate(_reserve);
        data.stableBorrowRate = core.getReserveCurrentStableBorrowRate(_reserve);
        data.averageStableBorrowRate = core.getReserveCurrentAverageStableBorrowRate(_reserve);
        data.utilizationRate = core.getReserveUtilizationRate(_reserve);
        data.liquidityIndex = core.getReserveLiquidityCumulativeIndex(_reserve);
        data.variableBorrowIndex = core.getReserveVariableBorrowsCumulativeIndex(_reserve);
        data.bTokenAddress = core.getReserveBTokenAddress(_reserve);
        data.lastUpdateTimestamp = core.getReserveLastUpdate(_reserve);

        return data;
    }

    function getUserAccountData(address _user)
        external
        view
        returns (
            uint256 totalLiquidityETH,
            uint256 totalCollateralETH,
            uint256 totalBorrowsETH,
            uint256 totalFeesETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        (
            totalLiquidityETH,
            totalCollateralETH,
            totalBorrowsETH,
            totalFeesETH,
            ltv,
            currentLiquidationThreshold,
            healthFactor,

        ) = calculateUserGlobalData(_user);

        availableBorrowsETH = calculateAvailableBorrowsETHInternal(
            totalCollateralETH,
            totalBorrowsETH,
            totalFeesETH,
            ltv
        );
    }

    function getUserReserveData(address _reserve, address _user) 
        external
        view 
        returns (
            uint256 currentBTokenBalance,
            uint256 currentBorrowBalance,
            uint256 principalBorrowBalance,
            uint256 borrowRateMode,
            uint256 borrowRate,
            uint256 liquidityRate,
            uint256 originationFee,
            uint256 variableBorrowIndex,
            uint256 lastUpdateTimestamp,
            bool usageAsCollateralEnabled
        )
    {
        currentBTokenBalance = BToken(core.getReserveBTokenAddress(_reserve)).balanceOf(_user);
        CoreLibrary.InterestRateMode mode = core.getUserCurrentBorrowRateMode(_reserve, _user);
        (principalBorrowBalance, currentBorrowBalance, ) = core.getUserBorrowBalances(_reserve, _user);

        //default is 0, if mode == CoreLibrary.InterestRateMode.NONE
        if(mode == CoreLibrary.InterestRateMode.STABLE) {
            borrowRate = core.getUserCurrentStableBorrowRate(_reserve, _user);
        } else if (mode == CoreLibrary.InterestRateMode.VARIABLE) {
            borrowRate = core.getReserveCurrentVariableBorrowRate(_reserve);
        }

        borrowRateMode = uint256(mode);
        liquidityRate = core.getReserveCurrentLiquidityRate(_reserve); 
        originationFee = core.getUserOriginationFee(_reserve, _user);
        variableBorrowIndex = core.getUserVariableBorrowCumulativeIndex(_reserve, _user);
        lastUpdateTimestamp = core.getUserLastUpdate(_reserve, _user);
        usageAsCollateralEnabled = core.isUserUseReserveAsCollateralEnabled(_reserve, _user);
    }
}
