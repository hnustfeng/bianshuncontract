//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "../proxys/InitializableWithSlot.sol";

import "../libraries/CoreLibrary.sol";
import "../libraries/EthAddressLib.sol";
import "../libraries/WadRayMath.sol";
import "../configuration/LendingPoolAddressesProvider.sol";
import "../tokenization/BToken.sol";
import "../interfaces/ILendingRateOracle.sol";
import "../interfaces/IReserveInterestRateStrategy.sol";

contract LendingPoolCore is InitializableWithSlot {
    using WadRayMath for uint256;
    using SafeMath for uint256;
    using CoreLibrary for CoreLibrary.ReserveData;
    using CoreLibrary for CoreLibrary.UserReserveData;
    using SafeERC20 for ERC20;
    using Address for address payable;

    event ReserveUpdate(
        address indexed reserve,
        uint256 liquidityRate,
        uint256 stableBorrowRate,
        uint256 variableBorrowRate,
        uint256 liquidtyIndex,
        uint256 variableBorrowIndex
    );
    
    address public lendingPoolAddress;

    LendingPoolAddressesProvider public addressesProvider;

    modifier onlyLendingPool {
        require(lendingPoolAddress == msg.sender, "The caller must be a lending pool contract");
        _;
    }

    modifier onlyLendingPoolConfigurator {
        require(
            addressesProvider.getLendingPoolConfigurator() == msg.sender,
            "The caller must be a lending pool configurator contract"
        );
        _;
    }

    mapping(address => CoreLibrary.ReserveData) internal reserves;
    mapping(address => mapping(address => CoreLibrary.UserReserveData)) internal usersReserveData;

    address[] public reservesList;

    function initialize(LendingPoolAddressesProvider _addressesProvider) public initializer {
        addressesProvider = _addressesProvider;
    }

    function updateStateOnDeposit(
        address _reserve,
        address _user,
        uint256 _amount,
        bool _isFirstDeposit
    ) external onlyLendingPool {
        reserves[_reserve].updateCumulativeIndexes();
        updateReserveInterestRatesAndTimestampInternal(_reserve, _amount, 0);

        if(_isFirstDeposit) {
            setUserUseReserveAsCollateral(_reserve, _user, true);
        }
    }

    function updateStateOnRedeem(
        address _reserve,
        address _user,
        uint256 _amountRedeemed,
        bool _userRedeemedEverything
    ) external onlyLendingPool {
        reserves[_reserve].updateCumulativeIndexes();
        updateReserveInterestRatesAndTimestampInternal(_reserve, 0, _amountRedeemed);

        if(_userRedeemedEverything) {
            setUserUseReserveAsCollateral(_reserve, _user, false);
        }
    }

    function updateStateOnBorrow(
        address _reserve,
        address _user,
        uint256 _amountBorrowed,
        uint256 _borrowFee,
        CoreLibrary.InterestRateMode _rateMode
    ) external onlyLendingPool returns(uint256, uint256) {
        (
            uint256 principalBorrowBalance,
            ,
            uint256 balanceIncrease
        ) = getUserBorrowBalances(_reserve, _user);

        
        updateReserveStateOnBorrowInternal(
            _reserve,
            _user,
            principalBorrowBalance,
            balanceIncrease,
            _amountBorrowed,
            _rateMode
        );

        updateUserStateOnBorrowInternal(
            _reserve,
            _user,
            _amountBorrowed,
            balanceIncrease,
            _borrowFee,
            _rateMode
        );
        updateReserveInterestRatesAndTimestampInternal(_reserve, 0, _amountBorrowed);

        return (getUserCurrentBorrowRate(_reserve, _user), balanceIncrease);
    }

    function updateStateOnRepay (
        address _reserve,
        address _user,
        uint256 _paybackAmountMinusFees,
        uint256 _originationFeeRepaid,
        uint256 _balanceIncrease,
        bool _repaidWholeLoan
    ) external onlyLendingPool {
        updateReserveStateOnRepayInternal(
            _reserve,
            _user,
            _paybackAmountMinusFees,
            _balanceIncrease
        );
        updateUserStateOnRepayInternal(
            _reserve,
            _user,
            _paybackAmountMinusFees,
            _originationFeeRepaid,
            _balanceIncrease,
            _repaidWholeLoan
        );

        updateReserveInterestRatesAndTimestampInternal(_reserve, _paybackAmountMinusFees, 0);
    }

    function updateStateOnSwapRate(
        address _reserve,
        address _user,
        uint256 _principalBorrowBalance,
        uint256 _compoundedBorrowBalance,
        uint256 _balanceIncrease,
        CoreLibrary.InterestRateMode _currentRateMode
    ) external onlyLendingPool returns (CoreLibrary.InterestRateMode, uint256) {
        updateReserveStateOnSwapRateInternal(
            _reserve,
            _user,
            _principalBorrowBalance,
            _compoundedBorrowBalance,
            _currentRateMode
        );

        CoreLibrary.InterestRateMode newRateMode = updateUserStateOnSwapRateInternal(
            _reserve,
            _user,
            _balanceIncrease,
            _currentRateMode
        );

        updateReserveInterestRatesAndTimestampInternal(_reserve, 0, 0);

        return (newRateMode, getUserCurrentBorrowRate(_reserve, _user));
    }

    function updateStateOnLiquidation(
        address _principalReserve,
        address _collateralReserve,
        address _user,
        uint256 _amountToLiquidate,
        uint256 _collateralToLiquidate,
        uint256 _feeLiquidated,
        uint256 _liquidatedCollateralForFee,
        uint256 _balanceIncrease,
        bool _liquidatorReceivesBtoken
    ) external onlyLendingPool {
        updatePrincipalReserveStateOnLiquidationInternal(
            _principalReserve,
            _user,
            _amountToLiquidate,
            _balanceIncrease
        );

        updateCollateralReserveStateOnLiquidationInternal(
            _collateralReserve
        );

        updateUserStateOnLiquidationInternal(
            _principalReserve,
            _user,
            _amountToLiquidate,
            _feeLiquidated,
            _balanceIncrease
        );

        updateReserveInterestRatesAndTimestampInternal(_principalReserve, _amountToLiquidate, 0);

        if(!_liquidatorReceivesBtoken) {
            updateReserveInterestRatesAndTimestampInternal(
                _collateralReserve,
                0,
                _collateralToLiquidate.add(_liquidatedCollateralForFee)
            );
        }
    }

    function updateStateOnRebalance(address _reserve, address _user, uint256 _balanceIncrease)
        external
        onlyLendingPool
        returns (uint256)
    {
        updateReserveStateOnRebalanceInternal(_reserve, _user, _balanceIncrease);

        updateUserStateOnRebalanceInternal(_reserve, _user, _balanceIncrease);
        updateReserveInterestRatesAndTimestampInternal(_reserve, 0, 0);

        return usersReserveData[_user][_reserve].stableBorrowRate;
    }

    function setUserUseReserveAsCollateral(address _reserve, address _user, bool _useAsCollateral)
        public
        onlyLendingPool
    {
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];
        user.useAsCollateral = _useAsCollateral;
    }

    //@notice ETH/token transfer function
    
    //only contracts can send ETH to the core
    fallback() external payable {
        require(msg.sender.code.length > 0, "Only contracts can send ether to the Lending pool core!");
    }

    receive() external payable {}

    function transferToUser(address _reserve, address payable _user, uint256 _amount) 
        external
        onlyLendingPool
    {
        if(_reserve != EthAddressLib.ethAddress()) {
            ERC20(_reserve).safeTransfer(_user, _amount);
        } else {
            (bool result, ) = _user.call{value: _amount, gas: 20000}("");
            require(result, "Transfer of ETH failed");
        }
    }

    function transferToFeeCollectionAddress(
        address _token,
        address _user,
        uint256 _amount,
        address _destination
    ) external payable onlyLendingPool {
        address payable feeAddress = payable(_destination);

        if(_token != EthAddressLib.ethAddress()) {
            require(msg.value == 0, "User is sending ETH along with the ERC20 transfer. Check the value attribute of the transaction!");
            ERC20(_token).safeTransferFrom(_user, feeAddress, _amount);
        } else {
            require(msg.value >= _amount, "The amount and the value sent to deposit do not match");

            (bool result, ) = feeAddress.call{value: _amount, gas: 20000}("");
            require(result, "Transfer of ETH failed");
        }
    }

    function liquidateFee(
        address _token,
        uint256 _amount,
        address _destination
    ) external payable onlyLendingPool {
        address payable feeAddress = payable(_destination);
        require(msg.value == 0, "Fee liquidation does not require any transfer of value");

        if(_token != EthAddressLib.ethAddress()) {
            ERC20(_token).safeTransfer(feeAddress, _amount);
        } else {
            (bool result, ) = feeAddress.call{value: _amount, gas: 20000}("");
            require(result, "Transfer of ETH failed");
        }
    }

    function transferToReserve(
        address _reserve,
        address payable _user,
        uint256 _amount
    ) external payable onlyLendingPool {
        if(_reserve != EthAddressLib.ethAddress()) {
            require(msg.value == 0, "User is sending ETH along with the ERC20 transfer!");
            ERC20(_reserve).safeTransferFrom(_user, address(this), _amount);
        } else {
            require(msg.value >= _amount, "The amount and the value sent to deposit do not match");

            if(msg.value > _amount) {
                uint256 excessAmount = msg.value.sub(_amount);

                (bool result, ) = _user.call{value: excessAmount, gas:20000}("");
                require(result, "Transfer of ETH failed");
            }
        }
    }
    //@notice data access function

    
    // avoid stack too deep
    function getReserveData(address _reserve) external view returns (CoreLibrary.ReserveData memory) {
        return reserves[_reserve];
    }

    //return user's balance, fee accrued, reserve enabled/disabled as collateral

    function getUserBasicReserveData(address _reserve, address _user)
        external view returns (uint256, uint256, uint256, bool)
    {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];

        uint256 underlyingBalance = getUserUnderlyingAssetBalance(_reserve, _user);

        if(user.principalBorrowBalance == 0) {
            return (underlyingBalance, 0, 0, user.useAsCollateral);
        }

        return (
            underlyingBalance,
            user.getCompoundedBorrowBalance(reserve),
            user.originationFee,
            user.useAsCollateral
        );
    }

    function isUserAllowedToBorrowAtStable(address _reserve, address _user, uint256 _amount)
        external
        view
        returns (bool)
    {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];

        if(!reserve.isStableBorrowRateEnabled) {
            return false;
        }

        return 
            !user.useAsCollateral ||
            !reserve.usageAsCollateralEnabled ||
            _amount > getUserUnderlyingAssetBalance(_reserve, _user);
    }

    function getUserUnderlyingAssetBalance(address _reserve, address _user)
        public 
        view
        returns (uint256)
    {
        BToken bToken = BToken(reserves[_reserve].bTokenAddress);
        return bToken.balanceOf(_user);
    }

    function getReserveInterestRateStrategyAddress(address _reserve)
        public view returns (address)
    {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.interestRateStrategyAddress;
    }

    function getReserveBTokenAddress(address _reserve)
        public 
        view
        returns (address)
    {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.bTokenAddress;
    }

    function getReserveAvailableLiquidity(address _reserve) public view returns(uint256) {
        uint256 balance = 0;

        if(_reserve == EthAddressLib.ethAddress()) {
            balance = address(this).balance;
        } else {
            balance = IERC20(_reserve).balanceOf(address(this));
        }
        return balance;
    }

    function getReserveTotalLiquidity(address _reserve) public view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return getReserveAvailableLiquidity(_reserve).add(reserve.getTotalBorrows());
    }

    function getReserveNormalizedIncome(address _reserve) external view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.getNormalizedIncome();
    }

    function getReserveTotalBorrows(address _reserve) public view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.getTotalBorrows();
    }

    function getReserveTotalBorrowsStable(address _reserve) external view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.totalBorrowsStable;
    }

    function getReserveTotalBorrowsVariable(address _reserve) external view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.totalBorrowsVariable;
    }

    function getReserveLiquidationThreshold(address _reserve) external view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.liquidationThreshold;
    }

    function getReserveLiquidationBonus(address _reserve) external view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.liquidationBonus;
    }

    function getReserveCurrentVariableBorrowRate(address _reserve) external view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];

        if(reserve.currentVariableBorrowRate == 0) {
            return 
                IReserveInterestRateStrategy(reserve.interestRateStrategyAddress)
                .getBaseVariableBorrowRate();
        }
        return reserve.currentVariableBorrowRate;
    }

    function getReserveCurrentStableBorrowRate(address _reserve) public view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        ILendingRateOracle oracle = ILendingRateOracle(addressesProvider.getLendingRateOracle());

        if(reserve.currentStableBorrowRate == 0) {
            return oracle.getMarketBorrowRate(_reserve);
        }

        return reserve.currentStableBorrowRate;
    }

    function getReserveCurrentAverageStableBorrowRate(address _reserve) external view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.currentAverageStableBorrowRate;
    }

    function getReserveCurrentLiquidityRate(address _reserve) external view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.currentLiquidityRate;
    }

    function getReserveLiquidityCumulativeIndex(address _reserve) external view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.lastLiquidityCumulativeIndex;
    }

    function getReserveVariableBorrowsCumulativeIndex(address _reserve)
        external
        view
        returns (uint256)
    {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.lastVariableBorrowCumulativeIndex;
    }

    function getReserveConfiguration(address _reserve)
        external
        view 
        returns(
            uint256, uint256, uint256, bool
        )
    {
        uint256 decimals;
        uint256 baseLTVasCollateral;
        uint256 liquidationThreshold;
        bool usageAsCollateralEnabled;

        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        decimals = reserve.decimals;
        baseLTVasCollateral = reserve.baseLTVasCollateral;
        liquidationThreshold = reserve.liquidationThreshold;
        usageAsCollateralEnabled = reserve.usageAsCollateralEnabled;
        
        return (decimals, baseLTVasCollateral, liquidationThreshold, usageAsCollateralEnabled);
    }

    function getReserveDecimals(address _reserve) external view returns (uint256) {
        return reserves[_reserve].decimals;
    }

    function isReserveBorrowingEnabled(address _reserve) external view returns (bool) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.borrowingEnabled;
    }

    function isReserveUsageAsCollateralEnabled(address _reserve) external view returns (bool) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.usageAsCollateralEnabled;
    }
    
    function getReserveIsStableBorrowRateEnabled(address _reserve) external view returns (bool) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.isStableBorrowRateEnabled;
    }

    function getReserveIsActive(address _reserve) external view returns (bool) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.isActive;
    }

    function getReserveIsFreezed(address _reserve) external view returns (bool) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        return reserve.isFreezed;
    }

    function getReserveLastUpdate(address _reserve) external view returns (uint40 timestamp) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        timestamp = reserve.lastUpdateTimestamp;
    }

    function getReserveUtilizationRate(address _reserve) public view returns (uint256) {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];

        uint256 totalBorrows = reserve.getTotalBorrows();

        if(totalBorrows == 0) {
            return 0;
        }

        uint256 availableLiquidity = getReserveAvailableLiquidity(_reserve);

        return totalBorrows.rayDiv(availableLiquidity.add(totalBorrows));
    } 

    function getReserves() external view returns (address[] memory) {
        return reservesList;
    }

    function isUserUseReserveAsCollateralEnabled(address _reserve, address _user) external view returns(bool) {
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];
        return user.useAsCollateral;
    }

    function getUserOriginationFee(address _reserve, address _user) 
        external 
        view
        returns(uint256)
    {
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];
        return user.originationFee;
    }

    function getUserCurrentBorrowRateMode(address _reserve, address _user)
        public
        view
        returns(CoreLibrary.InterestRateMode)
    {
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];

        if(user.principalBorrowBalance == 0) {
            return CoreLibrary.InterestRateMode.NONE;
        }

        return user.stableBorrowRate > 0 ? CoreLibrary.InterestRateMode.STABLE : CoreLibrary.InterestRateMode.VARIABLE;
    }

    function getUserCurrentBorrowRate(address _reserve, address _user) 
        internal
        view
        returns(uint256)
    {
        CoreLibrary.InterestRateMode rateMode = getUserCurrentBorrowRateMode(_reserve, _user);
        if(rateMode == CoreLibrary.InterestRateMode.NONE) {
            return 0;
        }
        return 
            rateMode == CoreLibrary.InterestRateMode.STABLE
            ? usersReserveData[_user][_reserve].stableBorrowRate
            : reserves[_reserve].currentVariableBorrowRate;
    }


    function getUserCurrentStableBorrowRate(address _reserve, address _user)
        external
        view
        returns(uint256)
    {
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];
        return user.stableBorrowRate;
    }

    function getUserBorrowBalances(address _reserve, address _user)
        public
        view
        returns(uint256, uint256, uint256)
    {
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];
        if(user.principalBorrowBalance == 0) {
            return (0, 0, 0);
        }
        
        uint256 principal = user.principalBorrowBalance;
        uint256 compoundedBalance = CoreLibrary.getCompoundedBorrowBalance(user, reserves[_reserve]);

        return (principal, compoundedBalance, compoundedBalance.sub(principal));
    }

    function getUserVariableBorrowCumulativeIndex(address _reserve, address _user)
        external
        view
        returns(uint256)
    {
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];
        return user.lastVariableBorrowCumulativeIndex;
    }

    function getUserLastUpdate(address _reserve, address _user)
        external 
        view 
        returns (uint256)
    {
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];
        return uint256(user.lastUpdateTimestamp); 
    }

    function refreshConfiguration() external onlyLendingPoolConfigurator {
        refreshConfigInternal();
    }

    function initReserve(address _reserve, address _bTokenAddress, uint256 _decimals, address _interestRateStrategyAddress)
        external
        onlyLendingPoolConfigurator
    {
        reserves[_reserve].init(_bTokenAddress, _decimals, _interestRateStrategyAddress);
        addReserveToListInternal(_reserve);
    }

    function removeLastAddedReserve(address _reserveToRemove) external onlyLendingPoolConfigurator {
        address lastReserve = reservesList[reservesList.length - 1];

        require(lastReserve == _reserveToRemove, "Reserve being removed is different than the reserve requrest");

        require(getReserveTotalBorrows(lastReserve) == 0, "Cannot remove a reserve with liquidity deposited");

        reserves[lastReserve].isActive = false;
        reserves[lastReserve].bTokenAddress = address(0);
        reserves[lastReserve].decimals = 0;
        reserves[lastReserve].lastLiquidityCumulativeIndex = 0;
        reserves[lastReserve].lastVariableBorrowCumulativeIndex = 0;
        reserves[lastReserve].borrowingEnabled = false;
        reserves[lastReserve].usageAsCollateralEnabled = false;
        reserves[lastReserve].baseLTVasCollateral = 0;
        reserves[lastReserve].liquidationThreshold = 0;
        reserves[lastReserve].liquidationBonus = 0;
        reserves[lastReserve].interestRateStrategyAddress = address(0);

        reservesList.pop();
    }

    function setReserveInterestRateStrategyAddress(address _reserve, address _rateStrategyAddress)
        external
        onlyLendingPoolConfigurator
    {
        reserves[_reserve].interestRateStrategyAddress = _rateStrategyAddress;
    }

    function enableBorrowingOnReserve(address _reserve, bool _stableBorrowRateEnabled)
        external
        onlyLendingPoolConfigurator
    {
        reserves[_reserve].enableBorrowing(_stableBorrowRateEnabled);
    }

    function disableBorrowingOnReserve(address _reserve)
        external
        onlyLendingPoolConfigurator
    {
        reserves[_reserve].disableBorrowing();
    }

    function enableReserveAsCollateral(
        address _reserve,
        uint256 _baseLTVasCollateral,
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus
    ) external onlyLendingPoolConfigurator {
        reserves[_reserve].enableAsCollateral(
            _baseLTVasCollateral,
            _liquidationThreshold,
            _liquidationBonus
        );
    }

    function disableReserveAsCollateral(address _reserve) external onlyLendingPoolConfigurator {
        reserves[_reserve].disableAsCollateral();
    }

    function enableReserveStableBorrowRate(address _reserve) external onlyLendingPoolConfigurator {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        reserve.isStableBorrowRateEnabled = true;
    }

    function disableReserveStableBorrowRate(address _reserve) external onlyLendingPoolConfigurator {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        reserve.isStableBorrowRateEnabled = false;
    }

    function activateReserve(address _reserve) external onlyLendingPoolConfigurator {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];

        require(
            reserve.lastLiquidityCumulativeIndex > 0 &&
                reserve.lastVariableBorrowCumulativeIndex > 0,
            "Reserve has not been initialized yet"
        );
        reserve.isActive = true;
    }

    function deactivateReserve(address _reserve) external onlyLendingPoolConfigurator {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        reserve.isActive = false;
    }

    function freezeReserve(address _reserve) external onlyLendingPoolConfigurator {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        reserve.isFreezed = true;
    }

    function unfreezeReserve(address _reserve) external onlyLendingPoolConfigurator {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        reserve.isFreezed = false;
    }

    function setReserveBaseLTVasCollateral(address _reserve, uint256 _ltv)
        external
        onlyLendingPoolConfigurator
    {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        reserve.baseLTVasCollateral = _ltv;
    }

    function setReserveLiquidationThreshold(address _reserve, uint256 _threshold)
        external
        onlyLendingPoolConfigurator
    {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        reserve.liquidationThreshold = _threshold;
    }

    function setReserveLiquidationBonus(address _reserve, uint256 _bonus)
        external
        onlyLendingPoolConfigurator
    {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        reserve.liquidationBonus = _bonus;
    }

    function setReserveDecimals(address _reserve, uint256 _decimals)
        external
        onlyLendingPoolConfigurator
    {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        reserve.decimals = _decimals;
    }

    //@notice: internal functions
    
    function updateReserveStateOnBorrowInternal(
        address _reserve,
        address _user,
        uint256 _principalBorrowBalance,
        uint256 _balanceIncrease,
        uint256 _amountBorrowed,
        CoreLibrary.InterestRateMode _rateMode
    ) internal {
        reserves[_reserve].updateCumulativeIndexes();

        updateReserveTotalBorrowsByRateModeInternal(
            _reserve,
            _user,
            _principalBorrowBalance,
            _balanceIncrease,
            _amountBorrowed,
            _rateMode
        );
    }

    function updateUserStateOnBorrowInternal(
        address _reserve,
        address _user,
        uint256 _amountBorrowed,
        uint256 _balanceIncrease,
        uint256 _fee,
        CoreLibrary.InterestRateMode _rateMode
    ) internal {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];

        if(_rateMode == CoreLibrary.InterestRateMode.STABLE) {
            user.stableBorrowRate = reserve.currentStableBorrowRate;
            user.lastVariableBorrowCumulativeIndex = 0;
        } else if (_rateMode == CoreLibrary.InterestRateMode.VARIABLE) {
            user.stableBorrowRate = 0;
            user.lastVariableBorrowCumulativeIndex = reserve.lastVariableBorrowCumulativeIndex;
        } else {
            revert("Invalid borrow rate mode");
        }

        user.principalBorrowBalance = user.principalBorrowBalance.add(_amountBorrowed).add(_balanceIncrease);

        user.originationFee = user.originationFee.add(_fee);

        user.lastUpdateTimestamp = uint40(block.timestamp);
    }

    function updateReserveStateOnRepayInternal(
        address _reserve,
        address _user,
        uint256 _paybackAmountMinusFees,
        uint256 _balanceIncrease
    ) internal {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];

        CoreLibrary.InterestRateMode borrowRateMode = getUserCurrentBorrowRateMode(_reserve, _user);

        reserves[_reserve].updateCumulativeIndexes();

        if(borrowRateMode == CoreLibrary.InterestRateMode.STABLE) {
            reserve.increaseTotalBorrowsStableAndUpdateAverageRate(
                _balanceIncrease,
                user.stableBorrowRate
            );
            reserve.decreaseTotalBorrowsStableAndUpdateAverageRate(
                _paybackAmountMinusFees,
                user.stableBorrowRate
            );
        } else {
            reserve.increaseTotalBorrowsVariable(_balanceIncrease);
            reserve.decreaseTotalBorrowsVariable(_paybackAmountMinusFees);
        }
    }

    function updateUserStateOnRepayInternal(
        address _reserve,
        address _user,
        uint256 _paybackAmountMinusFees,
        uint256 _originationFeeRepaid,
        uint256 _balanceIncrease,
        bool _repaidWholeLoan
    ) internal {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];

        user.principalBorrowBalance = user.principalBorrowBalance.add(_balanceIncrease).sub(_paybackAmountMinusFees);
        user.lastVariableBorrowCumulativeIndex = reserve.lastVariableBorrowCumulativeIndex;

        if(_repaidWholeLoan) {
            user.stableBorrowRate = 0;
            user.lastVariableBorrowCumulativeIndex = 0;
        }
        user.originationFee = user.originationFee.sub(_originationFeeRepaid);

        user.lastUpdateTimestamp = uint40(block.timestamp);
    }

    function updateReserveStateOnSwapRateInternal(
        address _reserve,
        address _user,
        uint256 _principalBorrowBalance,
        uint256 _compoundedBorrowBalance,
        CoreLibrary.InterestRateMode _currentRateMode
    ) internal {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];

        reserve.updateCumulativeIndexes();

        if(_currentRateMode == CoreLibrary.InterestRateMode.STABLE) {
            uint256 userCurrentStableRate = user.stableBorrowRate;

            reserve.decreaseTotalBorrowsStableAndUpdateAverageRate(
                _principalBorrowBalance,
                userCurrentStableRate
            );
            reserve.increaseTotalBorrowsVariable(_compoundedBorrowBalance);
        } else if(_currentRateMode == CoreLibrary.InterestRateMode.VARIABLE){
            uint256 currentStableRate = reserve.currentStableBorrowRate;
            reserve.decreaseTotalBorrowsVariable(_principalBorrowBalance);
            reserve.increaseTotalBorrowsStableAndUpdateAverageRate(
                _compoundedBorrowBalance,
                currentStableRate
            );
        } else {
            revert("Invalid rate mode received");
        }
    }

    function updateUserStateOnSwapRateInternal(
        address _reserve,
        address _user,
        uint256 _balanceIncrease,
        CoreLibrary.InterestRateMode _currentRateMode
    ) internal returns(CoreLibrary.InterestRateMode) {
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];

        CoreLibrary.InterestRateMode newMode = CoreLibrary.InterestRateMode.NONE;

        if(_currentRateMode == CoreLibrary.InterestRateMode.VARIABLE) {
            newMode = CoreLibrary.InterestRateMode.STABLE;
            user.stableBorrowRate = reserve.currentStableBorrowRate;
            user.lastVariableBorrowCumulativeIndex = 0;
        } else if (_currentRateMode == CoreLibrary.InterestRateMode.STABLE) {
            newMode = CoreLibrary.InterestRateMode.VARIABLE;
            user.stableBorrowRate = 0;
            user.lastVariableBorrowCumulativeIndex = reserve.lastVariableBorrowCumulativeIndex;
        } else {
            revert("Invalid interest rate mode received");
        }

        user.principalBorrowBalance = user.principalBorrowBalance.add(_balanceIncrease);
        user.lastUpdateTimestamp = uint40(block.timestamp);

        return newMode;
    }

    function updatePrincipalReserveStateOnLiquidationInternal(
        address _principalReserve,
        address _user,
        uint256 _amountToLiquidate,
        uint256 _balanceIncrease
    ) internal {
        CoreLibrary.ReserveData storage reserve = reserves[_principalReserve];
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_principalReserve];

        reserve.updateCumulativeIndexes();

        CoreLibrary.InterestRateMode borrowRateMode = getUserCurrentBorrowRateMode(
            _principalReserve,
            _user
        );

        if(borrowRateMode == CoreLibrary.InterestRateMode.STABLE) {
            reserve.increaseTotalBorrowsStableAndUpdateAverageRate(_balanceIncrease, user.stableBorrowRate);

            reserve.decreaseTotalBorrowsStableAndUpdateAverageRate(_amountToLiquidate, user.stableBorrowRate);
        } else {
            reserve.increaseTotalBorrowsVariable(_balanceIncrease);

            reserve.decreaseTotalBorrowsVariable(_amountToLiquidate);
        }
    }

    function updateCollateralReserveStateOnLiquidationInternal(
        address _collateralReserve
    ) internal {
        reserves[_collateralReserve].updateCumulativeIndexes();
    }

    function updateUserStateOnLiquidationInternal(
        address _reserve,
        address _user,
        uint256 _amountToLiquidate,
        uint256 _feeLiquidate,
        uint256 _balanceIncrease
    ) internal {
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];

        user.principalBorrowBalance = user.principalBorrowBalance.add(_balanceIncrease).sub(_amountToLiquidate);

        if(getUserCurrentBorrowRateMode(_reserve, _user) == CoreLibrary.InterestRateMode.VARIABLE) {
            user.lastVariableBorrowCumulativeIndex = reserve.lastVariableBorrowCumulativeIndex;
        }

        if(_feeLiquidate > 0) {
            user.originationFee = user.originationFee.sub(_feeLiquidate);
        }

        user.lastUpdateTimestamp = uint40(block.timestamp);
    }

    function updateReserveStateOnRebalanceInternal(
        address _reserve,
        address _user,
        uint256 _balanceIncrease
    ) internal {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];

        reserve.updateCumulativeIndexes();

        reserve.increaseTotalBorrowsStableAndUpdateAverageRate(
            _balanceIncrease,
            user.stableBorrowRate
        );
    }

    function updateUserStateOnRebalanceInternal(
        address _reserve,
        address _user,
        uint256 _balanceIncrease
    ) internal {
        CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];

        user.principalBorrowBalance = user.principalBorrowBalance.add(_balanceIncrease);
        user.stableBorrowRate = reserve.currentStableBorrowRate;

        user.lastUpdateTimestamp = uint40(block.timestamp);
    }

    function updateReserveTotalBorrowsByRateModeInternal(
        address _reserve,
        address _user,
        uint256 _principalBalance,
        uint256 _balanceIncrease,
        uint256 _amountBorrowed,
        CoreLibrary.InterestRateMode _newBorrowRateMode
    ) internal {
        CoreLibrary.InterestRateMode previousRateMode = getUserCurrentBorrowRateMode(_reserve, _user);
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];

        if(previousRateMode == CoreLibrary.InterestRateMode.STABLE) {
            CoreLibrary.UserReserveData storage user = usersReserveData[_user][_reserve];
            reserve.decreaseTotalBorrowsStableAndUpdateAverageRate(
                _principalBalance,
                user.stableBorrowRate
            );
        } else if (previousRateMode == CoreLibrary.InterestRateMode.VARIABLE) {
            reserve.decreaseTotalBorrowsVariable(_principalBalance);
        }

        uint256 newPrincipalAmount = _principalBalance.add(_balanceIncrease).add(_amountBorrowed);
        if(_newBorrowRateMode == CoreLibrary.InterestRateMode.STABLE) {
            reserve.increaseTotalBorrowsStableAndUpdateAverageRate(
                newPrincipalAmount,
                reserve.currentStableBorrowRate
            );
        } else if (_newBorrowRateMode == CoreLibrary.InterestRateMode.VARIABLE) {
            reserve.increaseTotalBorrowsVariable(newPrincipalAmount);
        } else {
            revert("Invalid new borrow rate mode");
        }
    }

    function updateReserveInterestRatesAndTimestampInternal(
        address _reserve,
        uint256 _liquidityAdded,
        uint256 _liquidityTaken
    ) internal {
        CoreLibrary.ReserveData storage reserve = reserves[_reserve];
        (
            uint256 newLiquidityRate,
            uint256 newStableRate,
            uint256 newVariableRate
        ) = IReserveInterestRateStrategy(
            reserve.interestRateStrategyAddress
        )
        .calculateInterestRates(
            _reserve,
            getReserveAvailableLiquidity(_reserve).add(_liquidityAdded).sub(_liquidityTaken),
            reserve.totalBorrowsStable,
            reserve.totalBorrowsVariable,
            reserve.currentAverageStableBorrowRate
        );
        
        reserve.currentLiquidityRate = newLiquidityRate;
        reserve.currentStableBorrowRate = newStableRate;
        reserve.currentVariableBorrowRate = newVariableRate;

        reserve.lastUpdateTimestamp = uint40(block.timestamp);

        emit ReserveUpdate(
            _reserve,
            newLiquidityRate,
            newStableRate,
            newVariableRate,
            reserve.lastLiquidityCumulativeIndex,
            reserve.lastVariableBorrowCumulativeIndex
        );
    }


    function refreshConfigInternal() internal {
        lendingPoolAddress = addressesProvider.getLendingPool();
    }

    function addReserveToListInternal(address _reserve) internal {
        bool reserveAlreadyAdded = false;
        for(uint256 i = 0; i < reservesList.length; i++) {
            if(reservesList[i] == _reserve) {
                reserveAlreadyAdded = true;
            }
        }
        if(!reserveAlreadyAdded) reservesList.push(_reserve);
    }
}