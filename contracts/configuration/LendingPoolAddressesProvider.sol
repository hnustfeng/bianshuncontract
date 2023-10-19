//SPDX-License-Identifier:MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../proxys/UUPSProxy.sol";

import "./AddressStorage.sol";

contract LendingPoolAddressesProvider is Ownable, AddressStorage {


    bytes32 private constant LENDING_POOL = "LENDING_POOL";
    bytes32 private constant LENDING_POOL_CORE = "LENDING_POOL_CORE";
    bytes32 private constant LENDING_POOL_CONFIGURATOR = "LENDING_POOL_CONFIGURATOR";
    bytes32 private constant LENDING_RATE_ORACLE = "LENDING_RATE_ORACLE";
    bytes32 private constant PRICE_ORACLE = "PRICE_ORACLE";
    bytes32 private constant FEE_PROVIDER = "FEE_PROVIDER";
    bytes32 private constant DATA_PROVIDER = "DATA_PROVIDER";
    bytes32 private constant LENDING_POOL_PARAMETERS_PROVIDER = "PARAMETERS_PROVIDER";
    bytes32 private constant TOKEN_DISTRIBUTOR = "TOKEN_DISTRIBUTOR";
    bytes32 private constant LENDING_POOL_LIQUIDATION_MANAGER = "LIQUIDATION_MANAGER";
    bytes32 private constant LENDING_POOL_MANAGER = "LENDING_POOL_MANAGER";

    event proxyCreated(bytes32 id, address indexed newAddress);
    event LendingPoolUpdated(address indexed newAddress);
    event LendingPoolCoreUpdated(address indexed newAddress);
    event LendingPoolConfiguratorUpdated(address indexed newAddress);
    event LendingRateOracleUpdated(address indexed newAddress);
    event PriceOracleUpdated(address indexed newAddress);
    event FeeProviderUpdated(address indexed newAddress);
    event DataProviderUpdated(address indexed newAddress);
    event LendingPoolParametersUpdated(address indexed newAddress);
    event TokenDistributorUpdated(address indexed newAddress);
    event LendingPoolLiquidationManagerUpdated(address indexed newAddress);
    event LendingPoolManagerUpdated(address indexed newAddress);

    function getLendingPool() public view returns(address) {
        return getAddress(LENDING_POOL);
    }

    function setLendingPool(address _pool) public onlyOwner {
        updateImplInternal(LENDING_POOL, _pool);
        emit LendingPoolUpdated(_pool);
    }

    function getLendingPoolCore() public view returns(address) {
        return getAddress(LENDING_POOL_CORE);
    }

    function setLendingPoolCore(address _core) public onlyOwner {
        updateImplInternal(LENDING_POOL_CORE, _core);
        emit LendingPoolCoreUpdated(_core);
    }

    function getLendingPoolConfigurator() public view returns(address) {
        return getAddress(LENDING_POOL_CONFIGURATOR);
    }

    function setLendingPoolConfigurator(address _configurator) public onlyOwner {
        updateImplInternal(LENDING_POOL_CONFIGURATOR, _configurator);
        emit LendingPoolConfiguratorUpdated(_configurator);
    }

    function setFeeProvider(address _feeProvider) public onlyOwner {
        updateImplInternal(FEE_PROVIDER, _feeProvider);
        emit FeeProviderUpdated(_feeProvider);
    }

    function getLendingPoolDataProvider() public view returns (address) {
        return getAddress(DATA_PROVIDER);
    }
    
    function setLendingPoolDataProvider(address _dataProvider) public onlyOwner{
        updateImplInternal(DATA_PROVIDER, _dataProvider);
        emit DataProviderUpdated(_dataProvider);
    }

    function getLendingPoolParametersProvider() public view returns (address) {
        return getAddress(LENDING_POOL_PARAMETERS_PROVIDER);
    }

    function setLendingPoolParametersProvider(address _parametersProvider) public onlyOwner{
        updateImplInternal(LENDING_POOL_PARAMETERS_PROVIDER, _parametersProvider);
        emit LendingPoolParametersUpdated(_parametersProvider);
    }

    function getTokenDistributor() public view returns (address) {
        return getAddress(TOKEN_DISTRIBUTOR);
    }

    function setTokenDistributor(address _distributor) public onlyOwner {
        _setAddress(TOKEN_DISTRIBUTOR, _distributor);
        emit TokenDistributorUpdated(_distributor);
    }

    function getLendingPoolLiquidationManager() public view returns (address) {
        return getAddress(LENDING_POOL_LIQUIDATION_MANAGER);
    }

    function setLendingPoolManager(address _lendingPoolManager) public onlyOwner {
        _setAddress(LENDING_POOL_MANAGER, _lendingPoolManager);
        emit LendingPoolManagerUpdated(_lendingPoolManager);
    }

    function getLendingPoolManager() public view returns (address) {
        return getAddress(LENDING_POOL_MANAGER);
    }

    function setLendingPoolLiquidationManager(address _liquidationManager) public onlyOwner {
        _setAddress(LENDING_POOL_LIQUIDATION_MANAGER, _liquidationManager);
        emit LendingPoolLiquidationManagerUpdated(_liquidationManager);
    }

    function getLendingRateOracle() public view returns(address) {
        return getAddress(LENDING_RATE_ORACLE);
    }

    function setLendingRateOracle(address _rateOracle) public onlyOwner {
        _setAddress(LENDING_RATE_ORACLE, _rateOracle);
        emit LendingRateOracleUpdated(_rateOracle);
    } 

    function getPriceOracle() public view returns (address) {
        return getAddress(PRICE_ORACLE);
    }

    function setPriceOracle(address _priceOracle) public onlyOwner {
        _setAddress(PRICE_ORACLE, _priceOracle);
        emit PriceOracleUpdated(_priceOracle);
    }

    function getFeeProvider() public view returns (address) {
        return getAddress(FEE_PROVIDER);
    }

    function updateImplInternal(bytes32 id, address newImpl) internal {
        address payable proxyAddress = payable(getAddress(id));

        if(proxyAddress == address(0)) {
            UUPSProxy proxy = new UUPSProxy(newImpl);
            _setAddress(id, address(proxy));
            emit proxyCreated(id, address(proxy));
        } else {
            UUPSProxy proxy = UUPSProxy(proxyAddress);
            proxy.updateImpl(newImpl);
        }
    }
}