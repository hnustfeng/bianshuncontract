/*
 * @Description: 
 * @Author: Martin
 * @Date: 2023-02-14 15:10:20
 * @LastEditors: Martin
 * @LastEditTime: 2023-05-16 15:03:20
 */
//SPDX-License-Identifier:MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../proxys/InitializableWithSlot.sol";

import "../configuration/LendingPoolAddressesProvider.sol";
import "../configuration/LendingPoolParametersProvider.sol";
import "../tokenization/BToken.sol";
import "../libraries/CoreLibrary.sol";
import "../libraries/WadRayMath.sol";
import "../libraries/EthAddressLib.sol";
import "../interfaces/IFeeProvider.sol";
import "./LendingPoolCore.sol";
import "./LendingPoolLiquidationManager.sol";
import "./LendingPoolDataProvider.sol";

contract LendingPool is ReentrancyGuard, InitializableWithSlot {
    using SafeMath for uint256;
    using WadRayMath for uint256;
    using Address for address;

    LendingPoolAddressesProvider public addressesProvider;
    LendingPoolCore public core;
    LendingPoolDataProvider public dataProvider;
    LendingPoolParametersProvider public parametersProvider;
    IFeeProvider feeProvider;

    event Deposit(
        address indexed _reserve,
        address indexed _user,
        uint256 _amount,
        uint16 indexed _referral,
        uint256 _timestamp
    );

    event RedeemUnderlying(
        address indexed _reserve,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    event Borrow(
        address indexed _reserve,
        address indexed _user,
        uint256 _amount,
        uint256 _borrowRateMode,
        uint256 _borrowRate,
        uint256 _originationFee,
        uint256 _borrowBalanceIncrease,
        uint16 indexed _referral,
        uint256 _timestamp
    );

    event Repay(
        address indexed _reserve,
        address indexed _user,
        address indexed _repayer,
        uint256 _amountMinusFees,
        uint256 _fees,
        uint256 _borrowBalanceIncrease,
        uint256 _timestamp
    );

    event Swap(
        address indexed _reserve,
        address indexed _user,
        uint256 _newRateMode,
        uint256 _newRate,
        uint256 _borrowBalanceIncrease,
        uint256 _timestamp
    );

    event ReserveUsedAsCollateralEnabled(address indexed _reserve, address indexed _user);

    event ReserveUsedAsCollateralDisabled(address indexed _reserve, address indexed _user);

    event RebalanceStableBorrowRate(
        address indexed _reserve,
        address indexed _user,
        uint256 _newStableRate,
        uint256 _borrowBalanceIncrease,
        uint256 _timestamp
    );

    //@notice: event FlashLoan

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

    modifier onlyOverlyingBToken(address _reserve) {
        require(
            msg.sender == core.getReserveBTokenAddress(_reserve),
            "The caller of this function can only be the bToken contract of this reserve"
        );
        _;
    }

    modifier onlyActiveReserve(address _reserve) {
        requireReserveActiveInternal(_reserve);
        _;
    }

    modifier onlyUnfreezedReserve(address _reserve) {
        requireReserveNotFreezedInternal(_reserve);
        _;
    }

    modifier onlyAmountGreaterThanZero(uint256 _amount) {
        requireAmountGreaterThanZeroInternal(_amount);
        _;
    }

    uint256 public constant UINT_MAX_VALUE = type(uint256).max;

    function initialize(LendingPoolAddressesProvider _addressesProvider) public initializer {
        addressesProvider = _addressesProvider;
        core = LendingPoolCore(payable(addressesProvider.getLendingPoolCore()));
        dataProvider = LendingPoolDataProvider(addressesProvider.getLendingPoolDataProvider());
        parametersProvider = LendingPoolParametersProvider(addressesProvider.getLendingPoolParametersProvider());
        feeProvider = IFeeProvider(addressesProvider.getFeeProvider());
    }


    
    function deposit(address _reserve, uint256 _amount, uint16 _referralCode)
        external
        payable
        nonReentrant
        onlyActiveReserve(_reserve)
        onlyUnfreezedReserve(_reserve)
        onlyAmountGreaterThanZero(_amount)
    {
        BToken bToken = BToken(core.getReserveBTokenAddress(_reserve));

        bool isFirstDeposit = bToken.balanceOf(msg.sender) == 0;

        core.updateStateOnDeposit(_reserve, msg.sender, _amount, isFirstDeposit);

        bToken.mintOnDeposit(msg.sender, _amount);

        core.transferToReserve{value: msg.value}(_reserve, payable(msg.sender), _amount);

        emit Deposit(_reserve, msg.sender, _amount, _referralCode, block.timestamp);

    }

    function redeemUnderlying(
        address _reserve,
        address payable _user,
        uint256 _amount,
        uint256 _bTokenBalanceAfterRedeem
    ) 
        external 
        nonReentrant 
        onlyOverlyingBToken(_reserve)
        onlyActiveReserve(_reserve)
        onlyAmountGreaterThanZero(_amount)
    {
        uint256 currentAvailableLiquidity = core.getReserveAvailableLiquidity(_reserve);
        require(
            currentAvailableLiquidity >= _amount,
            "There is not enough liquidity available to redeem"
        );

        core.updateStateOnRedeem(_reserve, _user, _amount, _bTokenBalanceAfterRedeem == 0);

        core.transferToUser(_reserve, _user, _amount);

        emit RedeemUnderlying(_reserve, _user, _amount, block.timestamp);
    }

    struct BorrowLocalVars {
        uint256 principalBorrowBalance;
        uint256 currentLtv;
        uint256 currentLiquidationThreshold;
        uint256 borrowFee;
        uint256 requestedBorrowAmountETH;
        uint256 amountOfCollateralNeededETH;
        uint256 userCollateralBalanceETH;
        uint256 userBorrowBalanceETH;
        uint256 userTotalFeesETH;
        uint256 borrowBalanceIncrease;
        uint256 currentReserveStableRate;
        uint256 availableLiquidity;
        uint256 reserveDecimals;
        uint256 finalUserBorrowRate;
        CoreLibrary.InterestRateMode rateMode;
        bool healthFactorBelowThreshold;
    }

    function borrow(
        address _reserve,
        uint256 _amount,
        uint256 _interestRateMode,
        uint16 _referralCode
    )
        external
        nonReentrant
        onlyActiveReserve(_reserve)
        onlyUnfreezedReserve(_reserve)
        onlyAmountGreaterThanZero(_amount)
    {
        BorrowLocalVars memory vars;

        require(core.isReserveBorrowingEnabled(_reserve), "Reserve is not enable for borrowing");

        require(
            uint256(CoreLibrary.InterestRateMode.VARIABLE) == _interestRateMode ||
            uint256(CoreLibrary.InterestRateMode.STABLE) == _interestRateMode,
            "Invalid interest rate mode selected"
        );

        vars.rateMode = CoreLibrary.InterestRateMode(_interestRateMode);

        vars.availableLiquidity = core.getReserveAvailableLiquidity(_reserve);

        require(vars.availableLiquidity >= _amount, "There is not enough liquidity available in the reserve");

        (
            ,
            vars.userCollateralBalanceETH,
            vars.userBorrowBalanceETH,
            vars.userTotalFeesETH,
            vars.currentLtv,
            vars.currentLiquidationThreshold,
            ,
            vars.healthFactorBelowThreshold
        ) = dataProvider.calculateUserGlobalData(msg.sender);

        require(vars.userCollateralBalanceETH > 0, "The collateral balance is 0");

        require(!vars.healthFactorBelowThreshold, "The borrower can already be liquidated so he cannot borrow more");

        //calculating fees
        vars.borrowFee = feeProvider.calculateLoanOriginationFee(msg.sender, _amount);
        
        require(vars.borrowFee > 0, "The amount to borrow is too small");

        vars.amountOfCollateralNeededETH = dataProvider.calculateCollateralNeededInETH(
            _reserve,
            _amount,
            vars.borrowFee,
            vars.userBorrowBalanceETH,
            vars.userTotalFeesETH,
            vars.currentLtv
        );

        require(
            vars.amountOfCollateralNeededETH <= vars.userCollateralBalanceETH,
            "There is not enough collateral to cover a new borrow"
        );

        if(vars.rateMode == CoreLibrary.InterestRateMode.STABLE) {
            require(
                core.isUserAllowedToBorrowAtStable(_reserve, msg.sender, _amount),
                "User cannot borrow the selected amount with a stable rate"
            );

            uint256 maxLoanPercent = parametersProvider.getMaxStableRateBorrowSizePercent();
            uint256 maxLoanSizeStable = vars.availableLiquidity.mul(maxLoanPercent).div(100);

            require(
                _amount <= maxLoanSizeStable,
                "User is trying to borrow too much liquidity at a stable rate"
            );
        }

        (vars.finalUserBorrowRate, vars.borrowBalanceIncrease) = core.updateStateOnBorrow(
            _reserve,
            msg.sender,
            _amount,
            vars.borrowFee,
            vars.rateMode
        );

        core.transferToUser(_reserve, payable(msg.sender), _amount);

        emit Borrow(
            _reserve,
            msg.sender,
            _amount,
            _interestRateMode,
            vars.finalUserBorrowRate,
            vars.borrowFee,
            vars.borrowBalanceIncrease,
            _referralCode,
            //solium-disable-next-line
            block.timestamp
        );
    }

    struct RepayLocalVars {
        uint256 principalBorrowBalance;
        uint256 compoundedBorrowBalance;
        uint256 borrowBalanceIncrease;
        bool isETH;
        uint256 paybackAmount;
        uint256 paybackAmountMinusFees;
        uint256 currentStableRate;
        uint256 originationFee;
    }

    function repay(address _reserve, uint256 _amount, address payable _onBehalfOf)
        external
        payable 
        nonReentrant 
        onlyActiveReserve(_reserve)
        onlyAmountGreaterThanZero(_amount)
    {

        RepayLocalVars memory vars;
        uint256 feeValue;

        (
            vars.principalBorrowBalance,
            vars.compoundedBorrowBalance,
            vars.borrowBalanceIncrease
        ) = core.getUserBorrowBalances(_reserve, _onBehalfOf);

        vars.originationFee = core.getUserOriginationFee(_reserve, _onBehalfOf);
        vars.isETH = EthAddressLib.ethAddress() == _reserve;

        require(vars.compoundedBorrowBalance > 0, "The user does not have any borrow pending");

        require(
            _amount != UINT_MAX_VALUE || msg.sender == _onBehalfOf,
            "To repay on behalf of an user an explicit amount to repay is needed"
        );

        //default to max amount
        vars.paybackAmount = vars.compoundedBorrowBalance.add(vars.originationFee);

        if(_amount != UINT_MAX_VALUE && _amount < vars.paybackAmount) {
            vars.paybackAmount = _amount;
        }

        require(
            !vars.isETH || msg.value >= vars.paybackAmount,
            "Invalid msg.value sent for the repayment"
        );

        //if the amount is smaller than the origination fee, just transfer the amount to the fee destination address
        if(vars.paybackAmount <= vars.originationFee) {
            core.updateStateOnRepay(
                _reserve,
                _onBehalfOf,
                0,
                vars.paybackAmount,
                vars.borrowBalanceIncrease,
                false
            );

            feeValue = vars.isETH ? vars.paybackAmount : 0;

            core.transferToFeeCollectionAddress{value: feeValue}(
                _reserve, 
                _onBehalfOf, 
                vars.paybackAmount, 
                addressesProvider.getTokenDistributor()
            );

            emit Repay(
                _reserve,
                _onBehalfOf,
                msg.sender,
                0,
                vars.paybackAmount,
                vars.borrowBalanceIncrease,
                //solium-disable-next-line
                block.timestamp
            );
            return;
        }

        vars.paybackAmountMinusFees = vars.paybackAmount.sub(vars.originationFee);

        core.updateStateOnRepay(
            _reserve,
            _onBehalfOf,
            vars.paybackAmountMinusFees,
            vars.originationFee,
            vars.borrowBalanceIncrease,
            vars.compoundedBorrowBalance == vars.paybackAmountMinusFees
        );

        //if the user didn't repay the origination fee, transfer the fee to the fee collection address
        if(vars.originationFee > 0) {
            feeValue = vars.isETH ? vars.originationFee : 0;

            core.transferToFeeCollectionAddress{value: feeValue}(
                _reserve,
                msg.sender,
                vars.originationFee,
                addressesProvider.getTokenDistributor()
            );
        }
        //sending the total msg.value if the transfer is ETH.
        //the transferToReserve() function will take care of sending the
        //excess ETH back to the caller
        feeValue = vars.isETH ? msg.value.sub(vars.originationFee) : 0;
        core.transferToReserve{value: feeValue}(_reserve, payable(msg.sender), vars.paybackAmountMinusFees);

        emit Repay(
            _reserve,
            _onBehalfOf,
            msg.sender,
            vars.paybackAmountMinusFees,
            vars.originationFee,
            vars.borrowBalanceIncrease,
            //solium-disable-next-line
            block.timestamp
        );
    }

    function swapBorrowRateMode(address _reserve) 
        external
        nonReentrant
        onlyActiveReserve(_reserve)
        onlyUnfreezedReserve(_reserve)
    {
        (uint256 principalBorrowBalance, uint256 compoundedBorrowBalance, uint256 borrowBalanceIncrease) = core
            .getUserBorrowBalances(_reserve, msg.sender);

        require(compoundedBorrowBalance > 0, "User does not have a borrow in progress on this reserve");

        CoreLibrary.InterestRateMode currentRateMode = core.getUserCurrentBorrowRateMode(_reserve, msg.sender);

        if(currentRateMode == CoreLibrary.InterestRateMode.VARIABLE) {
            /**
            * user wants to swap to stable, before swapping we need to ensure that
            * 1. stable borrow rate is enabled on the reserve
            * 2. user is not trying to abuse the reserve by depositing
            * more collateral than he is borrowing, artificially lowering
            * the interest rate, borrowing at variable, and switching to stable
            **/
            require(
                core.isUserAllowedToBorrowAtStable(_reserve, msg.sender, compoundedBorrowBalance),
                "User cannot borrow the selected amount at stable"
            );
        }

        (CoreLibrary.InterestRateMode newRateMode, uint256 newBorrowRate) = core
            .updateStateOnSwapRate(
                _reserve,
                msg.sender,
                principalBorrowBalance,
                compoundedBorrowBalance,
                borrowBalanceIncrease,
                currentRateMode
            );
        
        emit Swap(
            _reserve,
            msg.sender,
            uint256(newRateMode),
            newBorrowRate,
            borrowBalanceIncrease,
            //solium-disable-next-line
            block.timestamp
        );
    }

    //@todo:rebalanceStableBorrowRate
    function rebalanceStableBorrowRate(address _reserve, address _user)
        external
        nonReentrant
        onlyActiveReserve(_reserve)
    {
        (
            ,
            uint256 compoundedBalance,
            uint256 borrowBalanceIncrease
        ) = core.getUserBorrowBalances(_reserve, _user);

        //step 1: user must be borrowing on _reserve at a stable rate
        require(compoundedBalance > 0, "User does not have any borrow for this reserve");

        require(
            core.getUserCurrentBorrowRateMode(_reserve, _user) == CoreLibrary.InterestRateMode.STABLE,
            "The user borrow is variable and cannot be rebalanced"
        );

        uint256 userCurrentStableRate = core.getUserCurrentStableBorrowRate(_reserve, _user);
        uint256 liquidityRate = core.getReserveCurrentLiquidityRate(_reserve);
        uint256 reserveCurrentStableRate = core.getReserveCurrentStableBorrowRate(_reserve);
        uint256 rebalanceDownRateThreshold = reserveCurrentStableRate
            .rayMul(
                WadRayMath.ray().add(parametersProvider.getRebalanceDownRateDelta())
            );
        
        //step 2: we have two possible situations to rebalance:

        //1. user stable borrow rate is below the current liquidity rate. The loan needs to be rebalanced,
        //as this situation can be abused (user putting back the borrowed liquidity in the same reserve to earn on it)
        //2. user stable rate is above the market avg borrow rate of a certain delta, and utilization rate is low.
        //In this case, the user is paying an interest that is too high, and needs to be rescaled down.
        if(
            userCurrentStableRate < liquidityRate ||
            userCurrentStableRate > rebalanceDownRateThreshold
        ) {
            uint256 newStableRate = core.updateStateOnRebalance(
                _reserve,
                _user,
                borrowBalanceIncrease
            );

            emit RebalanceStableBorrowRate(
                _reserve,
                _user,
                newStableRate,
                borrowBalanceIncrease,
                //solium-disable-next-line
                block.timestamp
            );

            return ;
        }

        revert("Interest rate rebalance conditions were not met");
    }

    function setUserUseReserveAsCollateral(address _reserve, bool _useAsCollateral)
        external
        nonReentrant
        onlyActiveReserve(_reserve)
        onlyUnfreezedReserve(_reserve)
    {
        uint256 underlyingBalance = core.getUserUnderlyingAssetBalance(_reserve, msg.sender);

        require(underlyingBalance > 0, "User does not have any liquidity deposited");

        require(
            dataProvider.balanceDecreaseAllowed(_reserve, msg.sender, underlyingBalance),
            "User deposit is already being used as collateral"
        );

        core.setUserUseReserveAsCollateral(_reserve, msg.sender, _useAsCollateral);

        if(_useAsCollateral) {
            emit ReserveUsedAsCollateralEnabled(_reserve, msg.sender);
        } else {
            emit ReserveUsedAsCollateralDisabled(_reserve, msg.sender);
        }
    }

    function liquidationCall(
        address _collateral,
        address _reserve,
        address _user,
        uint256 _purchaseAmount,
        bool _receiveBToken
    ) 
        external 
        payable 
        nonReentrant 
        onlyActiveReserve(_reserve) 
        onlyActiveReserve(_collateral)
    {
        address liquidationManager = addressesProvider.getLendingPoolLiquidationManager();

        (
            bool success,
            bytes memory result 
        ) = liquidationManager.delegatecall(
            abi.encodeWithSignature(
                "liquidationCall(address,address,address,uint256,bool)", 
                _collateral,
                _reserve,
                _user,
                _purchaseAmount,
                _receiveBToken
            )
        );
        require(success, "Liquidation call failed");

        (uint256 returnCode, string memory returnMessage) = abi.decode(result, (uint256, string));

        if(returnCode != 0) {
            revert(string(abi.encodePacked("Liquidation failed: ", returnMessage)));
        }
    }

    //@todo: function flashLoan

    function getReserveConfigurationData(address _reserve)
        external
        view
        returns(
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            address interestRateStrategyAddress,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive
        )
    {
        return dataProvider.getReserveConfigurationData(_reserve);
    }

    function getReserveData(address _reserve)
        external
        view
        returns (
            LendingPoolDataProvider.Reserve memory
        )
    {
        return dataProvider.getReserveData(_reserve);
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
        return dataProvider.getUserAccountData(_user);
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
        return dataProvider.getUserReserveData(_reserve, _user);
    }

    function getReserves() external view returns (address[] memory) {
        return core.getReserves();
    }

    function requireReserveActiveInternal(address _reserve) internal view {
        require(core.getReserveIsActive(_reserve), "Action requires an active reserve");
    }

    function requireReserveNotFreezedInternal(address _reserve) internal view {
        require(!core.getReserveIsFreezed(_reserve), "Action requires an unfreezed reserve");
    }

    function requireAmountGreaterThanZeroInternal(uint256 _amount) internal pure {
        require(_amount > 0, "Amount must greater than 0");
    }
}
