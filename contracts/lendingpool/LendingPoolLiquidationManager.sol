//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../proxys/InitializableWithSlot.sol";
import "../configuration/LendingPoolAddressesProvider.sol";
import "../configuration/LendingPoolParametersProvider.sol";
import "../tokenization/BToken.sol";
import "../libraries/CoreLibrary.sol";
import "../libraries/WadRayMath.sol";
import "../interfaces/IPriceOracleGetter.sol";
import "./LendingPoolCore.sol";
import "./LendingPoolDataProvider.sol";

contract LendingPoolLiquidationManager is ReentrancyGuard, InitializableWithSlot {
    using SafeMath for uint256;
    using WadRayMath for uint256;
    using Address for address;

    LendingPoolAddressesProvider public addressesProvider;
    LendingPoolCore core;
    LendingPoolDataProvider dataProvider;
    LendingPoolParametersProvider parametersProvider;
    IFeeProvider feeProvider;
    address ethereumAddress;

    uint256 constant LIQUIDATION_CLOSE_FACTOR_PERCENT = 50;

    event OriginationFeeLiquidated(
        address indexed _collateral,
        address indexed _reserve,
        address indexed _user,
        uint256 _feeLiquidated,
        uint256 _liquidatedCollateralForFee,
        uint256 _timestamp
    );

    event LiquidationCall(
        address indexed _collateral,
        address indexed _reserve,
        address indexed _user,
        uint256 _purchaseAmount,
        uint256 _liquidatedCollateralAmount,
        uint256 _accruedBorrowInterest,
        address _liquidator,
        bool _receiveBToken,
        uint256 _timestamp
    );

    enum LiquidationErrors {
        NO_ERROR,
        NO_COLLATERAL_AVAILABLE,
        COLLATERAL_CANNOT_BE_LIQUIDATED,
        CURRRENCY_NOT_BORROWED,
        HEALTH_FACTOR_ABOVE_THRESHOLD,
        NOT_ENOUGH_LIQUIDITY
    }

    struct LiquidationCallLocalVars {
        uint256 userCollateralBalance;
        uint256 userCompoundedBorrowBalance;
        uint256 borrowBalanceIncrease;
        uint256 maxPrincipalAmountToLiquidate;
        uint256 actualAmountToLiquidate;
        uint256 liquidationRatio;
        uint256 collateralPrice;
        uint256 principalCurrencyPrice;
        uint256 maxAmountCollateralToLiquidate;
        uint256 originationFee;
        uint256 feeLiquidated;
        uint256 liquidatedCollateralForFee;
        CoreLibrary.InterestRateMode borrowRateMode;
        uint256 userStableRate;
        bool isCollateralEnabled;
        bool healthFactorBelowThreshold;
    }

    function liquidationCall(
        address _collateral,
        address _reserve,
        address _user,
        uint256 _purchaseAmount,
        bool _receiveBToken
    ) external payable returns (uint256, string memory) {
        LiquidationCallLocalVars memory vars;

        (, , , , , , , vars.healthFactorBelowThreshold) = dataProvider.calculateUserGlobalData(_user);

        if(!vars.healthFactorBelowThreshold) {
            return (
                uint256(LiquidationErrors.HEALTH_FACTOR_ABOVE_THRESHOLD),
                "Health factor is not below the threshold"
            );
        }

        vars.userCollateralBalance = core.getUserUnderlyingAssetBalance(_collateral, _user);

        //if _user hasn't deposited this specific collateral, nothing can be liquidated
        if(vars.userCollateralBalance == 0) {
            return (
                uint256(LiquidationErrors.NO_COLLATERAL_AVAILABLE),
                "Invalid collateral to liquidate"
            );
        }

        vars.isCollateralEnabled = 
            core.isReserveUsageAsCollateralEnabled(_collateral) &&
            core.isUserUseReserveAsCollateralEnabled(_collateral, _user);

        //if _collateral isn't enabled as collateral by _user, it cannot be liquidated
        if(!vars.isCollateralEnabled) {
            return (
                uint256(LiquidationErrors.COLLATERAL_CANNOT_BE_LIQUIDATED),
                "The collateral chosen cannot be liquidated"
            );
        }

        //if the user hasn't borrowed the specific currency defined by _reserve, it cannot be liquidated
        (, vars.userCompoundedBorrowBalance, vars.borrowBalanceIncrease) = core
            .getUserBorrowBalances(_reserve, _user);

        if(vars.userCompoundedBorrowBalance == 0) {
            return (
                uint256(LiquidationErrors.CURRRENCY_NOT_BORROWED),
                "User did not borrow the specified currency"
            );
        }

        //all clear - calculate the max principal amount that can be liquidated
        vars.maxPrincipalAmountToLiquidate = vars
            .userCompoundedBorrowBalance
            .mul(LIQUIDATION_CLOSE_FACTOR_PERCENT)
            .div(100);

        vars.actualAmountToLiquidate = _purchaseAmount > vars.maxPrincipalAmountToLiquidate
            ? vars.maxPrincipalAmountToLiquidate
            : _purchaseAmount;
        
        (uint256 maxCollateralToLiquidate, uint256 principalAmountNeeded) = calculateAvailableCollateralToLiquidate(
            _collateral,
            _reserve,
            vars.actualAmountToLiquidate,
            vars.userCollateralBalance
        );

        vars.originationFee = core.getUserOriginationFee(_reserve, _user);

        //if there is a fee to liquidate, calculate the maximum amount of fee that can be liquidated
        if(vars.originationFee > 0) {
            (
                vars.liquidatedCollateralForFee,
                vars.feeLiquidated
            ) = calculateAvailableCollateralToLiquidate(
                _collateral,
                _reserve,
                vars.originationFee,
                vars.userCollateralBalance.sub(maxCollateralToLiquidate)
            );
        }

        //if principalAmountNeeded < vars.ActualAmountToLiquidate, there isn't enough
        //of _collateral to cover the actual amount that is being liquidated, hence we liquidate
        //a smaller amount
        if(principalAmountNeeded < vars.actualAmountToLiquidate) {
            vars.actualAmountToLiquidate = principalAmountNeeded;
        }

        //if liquidator reclaims the underlying asset, we make sure there is enough available collateral in the reserve
        if(!_receiveBToken) {
            uint256 currentAvailableCollateral = core.getReserveAvailableLiquidity(_collateral);
            if(currentAvailableCollateral < maxCollateralToLiquidate) {
                return (
                    uint256(LiquidationErrors.NOT_ENOUGH_LIQUIDITY),
                    "There isn't enough liquidity available to liquidate"
                );
            }
        }

        core.updateStateOnLiquidation(
            _reserve,
            _collateral,
            _user,
            vars.actualAmountToLiquidate,
            maxCollateralToLiquidate,
            vars.feeLiquidated,
            vars.liquidatedCollateralForFee,
            vars.borrowBalanceIncrease,
            _receiveBToken
        );

        BToken collateralBtoken = BToken(core.getReserveBTokenAddress(_collateral));

        //if liquidator reclaims the bToken, he receives the equivalent btoken amount
        if(_receiveBToken) {
            collateralBtoken.transferOnLiquidation(_user, msg.sender, maxCollateralToLiquidate);
        } else {
            //otherwise receives the underlying asset
            //burn the equivalent amount of btoken
            collateralBtoken.burnOnLiquidation(_user, maxCollateralToLiquidate);
            core.transferToUser(_collateral, payable(msg.sender), maxCollateralToLiquidate);
        }

        core.transferToReserve{value: msg.value}(_reserve, payable(msg.sender), vars.actualAmountToLiquidate);//@notice:Maybe there is a {value: msg.value}

        if(vars.feeLiquidated > 0) {
            //if there is enough collateral to liquidate the fee, first transfer burn an equivalent amount of
            //bTokens of the user
            collateralBtoken.burnOnLiquidation(_user, vars.liquidatedCollateralForFee);

            //then liquidate the fee by transferring it to the fee collection address
            core.liquidateFee(
                _collateral, 
                vars.liquidatedCollateralForFee,
                addressesProvider.getTokenDistributor()
            );

            emit OriginationFeeLiquidated(
                _collateral,
                _reserve,
                _user,
                vars.feeLiquidated,
                vars.liquidatedCollateralForFee,
                //solium-disable-next-line
                block.timestamp
            );
        }
        emit LiquidationCall(
            _collateral,
            _reserve,
            _user,
            vars.actualAmountToLiquidate,
            maxCollateralToLiquidate,
            vars.borrowBalanceIncrease,
            msg.sender,
            _receiveBToken,
            //solium-disable-next-line
            block.timestamp
        );

        return (uint256(LiquidationErrors.NO_ERROR), "No errors");
    }

    struct AvailableCollateralToLiquidateLocalVars {
        uint256 userCompoundedBorrowBalance;
        uint256 liquidationBonus;
        uint256 collateralPrice;
        uint256 principalCurrencyPrice;
        uint256 maxAmountCollateralToLiquidate;
    }

    function calculateAvailableCollateralToLiquidate(
        address _collateral,
        address _principal,
        uint256 _purchaseAmount,
        uint256 _userCollateralBalance
    ) internal view returns (uint256 collateralAmount, uint256 principalAmountNeeded) {
        collateralAmount = 0;
        principalAmountNeeded = 0;
        IPriceOracleGetter oracle = IPriceOracleGetter(addressesProvider.getPriceOracle());

        // Usage of a memory struct of vars to avoid "Stack too deep" errors due to local variables
        AvailableCollateralToLiquidateLocalVars memory vars;

        vars.collateralPrice = oracle.getAssetPrice(_collateral);
        vars.principalCurrencyPrice = oracle.getAssetPrice(_principal);
        vars.liquidationBonus = core.getReserveLiquidationBonus(_collateral);

        //this is the maximum possible amount of the selected collateral that can be liquidated, given the
        //max amount of principal currency that is available for liquidation.
        vars.maxAmountCollateralToLiquidate = vars
            .principalCurrencyPrice
            .mul(_purchaseAmount)
            .div(vars.collateralPrice)
            .mul(vars.liquidationBonus)
            .div(100);

        if(vars.maxAmountCollateralToLiquidate > _userCollateralBalance) {
            collateralAmount = _userCollateralBalance;
            principalAmountNeeded = vars
                .collateralPrice
                .mul(collateralAmount)
                .div(vars.principalCurrencyPrice)
                .mul(100)
                .div(vars.liquidationBonus);
        } else {
            collateralAmount = vars.maxAmountCollateralToLiquidate;
            principalAmountNeeded = _purchaseAmount;
        }

        return (collateralAmount, principalAmountNeeded);
    }
}