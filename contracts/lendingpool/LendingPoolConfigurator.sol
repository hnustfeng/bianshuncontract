//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../proxys/InitializableWithSlot.sol";

import "../configuration/LendingPoolAddressesProvider.sol";
import "./LendingPoolCore.sol";
import "../tokenization/BToken.sol";

contract LendingPoolConfigurator is InitializableWithSlot {
    using SafeMath for uint256;

    event ReserveInitialized(
        address indexed _reserve,
        address indexed _bToken,
        address _interestRateStrategyAddress
    );

    event ReserveRemoved(
        address indexed _reserve
    );

    event BorrowingEnabledOnReserve(address _reserve, bool _stableRateEnabled);

    event BorrowingDisabledOnReserve(address indexed _reserve);

    event ReserveEnabledAsCollateral(
        address indexed _reserve,
        uint256 _ltv,
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus
    );

    event ReserveDisabledAsCollateral(address indexed _reserve);

    event StableRateEnabledOnReserve(address indexed _reserve);

    event StableRateDisabledOnReserve(address indexed _reserve);

    event ReserveActivated(address indexed _reserve);

    event ReserveDeactivated(address indexed _reserve);

    event ReserveFreezed(address indexed _reserve);

    event ReserveUnfreezed(address indexed _reserve);

    event ReserveBaseLtvChanged(address _reserve, uint256 _ltv);

    event ReserveLiquidationThresholdChanged(address _reserve, uint256 _threshold);

    event ReserveLiquidationBonusChanged(address _reserve, uint256 _bonus);

    event ReserveDecimalsChanged(address _reserve, uint256 _decimals);

    event ReserveInterestRateStrategyChanged(address _reserve, address _strategy);

    LendingPoolAddressesProvider public poolAddressesProvider;

    modifier onlyLendingPoolManager {
        require(
            poolAddressesProvider.getLendingPoolManager() == msg.sender,
            "The caller must be a lending pool manager"
        );
        _;
    }

    function initialize(LendingPoolAddressesProvider _poolAddressProvider) public initializer {
        poolAddressesProvider = _poolAddressProvider;
    }

    function initReserve(
        address _reserve,
        uint8 _underlyingAssetDecimals,
        address _interestRateStrategyAddress
    ) external onlyLendingPoolManager {
        ERC20 asset = ERC20(_reserve);

        string memory bTokenName = string(abi.encodePacked("Biansun Interest bearing", asset.name()));
        string memory bTokenSymbol = string(abi.encodePacked("b", asset.symbol()));

        initReserveWithData(
            _reserve,
            bTokenName,
            bTokenSymbol,
            _underlyingAssetDecimals,
            _interestRateStrategyAddress
        );
    }

    function initReserveWithData(
        address _reserve,
        string memory _bTokenName,
        string memory _bTokenSymbol,
        uint8 _underlyingAssetDecimals,
        address _interestRateStrategyAddress
    ) public onlyLendingPoolManager {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));

        BToken bTokenInstance = new BToken(
            poolAddressesProvider,
            _reserve,
            _underlyingAssetDecimals,
            _bTokenName,
            _bTokenSymbol
        );
        core.initReserve(
            _reserve,
            address(bTokenInstance),
            _underlyingAssetDecimals,
            _interestRateStrategyAddress
        );

        emit ReserveInitialized( 
            _reserve,
            address(bTokenInstance),
            _interestRateStrategyAddress
        );
    }

    function removeLastAddedReserve(address _reserveToRemove) external onlyLendingPoolManager{
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.removeLastAddedReserve(_reserveToRemove);
        emit ReserveRemoved(_reserveToRemove);
    }

    function enableBorrowingOnReserve(address _reserve, bool _stableBorrowRateEnabled)
        external
        onlyLendingPoolManager
    {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.enableBorrowingOnReserve(_reserve, _stableBorrowRateEnabled);
        emit BorrowingEnabledOnReserve(_reserve, _stableBorrowRateEnabled);
    }

    function disableBorrowingOnReserve(address _reserve) external onlyLendingPoolManager {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.disableBorrowingOnReserve(_reserve);

        emit BorrowingDisabledOnReserve(_reserve);
    }

    function enableReserveAsCollateral(
        address _reserve,
        uint256 _baseLTVasCollateral,
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus
    ) external onlyLendingPoolManager {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.enableReserveAsCollateral(_reserve, _baseLTVasCollateral, _liquidationThreshold, _liquidationBonus);

        emit ReserveEnabledAsCollateral(_reserve, _baseLTVasCollateral, _liquidationThreshold, _liquidationBonus);
    }

    function disableReserveAsCollateral(address _reserve) external onlyLendingPoolManager {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.disableReserveAsCollateral(_reserve);

        emit ReserveDisabledAsCollateral(_reserve);
    }

    function enableReserveStableBorrowRate(address _reserve) external onlyLendingPoolManager {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.enableReserveStableBorrowRate(_reserve);

        emit StableRateEnabledOnReserve(_reserve);
    }

    function disableReserveStableBorrowRate(address _reserve) external onlyLendingPoolManager {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.disableReserveStableBorrowRate(_reserve);

        emit StableRateDisabledOnReserve(_reserve);
    }

    function activateReserve(address _reserve) external onlyLendingPoolManager {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.activateReserve(_reserve);

        emit ReserveActivated(_reserve);
    }

    function deactivateReserve(address _reserve) external onlyLendingPoolManager {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        require(core.getReserveTotalLiquidity(_reserve) == 0, "The liquidity of the reserve needs to be 0");
        core.deactivateReserve(_reserve);

        emit ReserveDeactivated(_reserve);
    }

    function freezeReserve(address _reserve) external onlyLendingPoolManager {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.freezeReserve(_reserve);

        emit ReserveFreezed(_reserve);
    }

    function unfreezeReserve(address _reserve) external onlyLendingPoolManager {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.unfreezeReserve(_reserve);

        emit ReserveUnfreezed(_reserve);
    }

    function setReserveBaseLTVasCollateral(address _reserve, uint256 _ltv)
        external
        onlyLendingPoolManager
    {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.setReserveBaseLTVasCollateral(_reserve, _ltv);
        emit ReserveBaseLtvChanged(_reserve, _ltv);
    }

    function setReserveLiquidationThreshold(address _reserve, uint256 _threshold)
        external
        onlyLendingPoolManager
    {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.setReserveLiquidationThreshold(_reserve, _threshold);
        emit ReserveLiquidationThresholdChanged(_reserve, _threshold);
    }

    function setReserveLiquidationBonus(address _reserve, uint256 _bonus)
        external
        onlyLendingPoolManager
    {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.setReserveLiquidationBonus(_reserve, _bonus);
        emit ReserveLiquidationBonusChanged(_reserve, _bonus);
    }

    function setReserveDecimals(address _reserve, uint256 _decimals)
        external
        onlyLendingPoolManager
    {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.setReserveDecimals(_reserve, _decimals);
        emit ReserveDecimalsChanged(_reserve, _decimals);
    }

    function setReserveInterestRateStrategyAddress(address _reserve, address _rateStrategyAddress)
        external
        onlyLendingPoolManager
    {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.setReserveInterestRateStrategyAddress(_reserve, _rateStrategyAddress);
        emit ReserveInterestRateStrategyChanged(_reserve, _rateStrategyAddress);
    }

    function refreshLendingPoolCoreConfiguration() external onlyLendingPoolManager {
        LendingPoolCore core = LendingPoolCore(payable(poolAddressesProvider.getLendingPoolCore()));
        core.refreshConfiguration();
    }
}