//SPDX-License-Identifier:MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../configuration/LendingPoolAddressesProvider.sol";
import "../lendingpool/LendingPool.sol";
import "../lendingpool/LendingPoolDataProvider.sol";
import "../lendingpool/LendingPoolCore.sol";
import "../libraries/WadRayMath.sol";


contract BToken is ERC20 {
    using WadRayMath for uint256;
    using SafeMath for uint256;

    uint256 public constant UINT_MAX_VALUE = type(uint256).max;

    event Redeem(
        address indexed _from,
        uint256 _value,
        uint256 _fromBalanceIncrease,
        uint256 _fromIndex
    );

    event MintOnDeposit(
        address indexed _from,
        uint256 _value,
        uint256 _fromBalanceIncrease,
        uint256 _fromIndex
    );

    event BurnOnLiquidation(
        address indexed _from,
        uint256 _value,
        uint256 _fromBalanceIncrease,
        uint256 _fromIndex
    );

    event BalanceTransfer(
        address indexed _from,
        address indexed _to,
        uint256 _value,
        uint256 _fromBalanceIncrease,
        uint256 _toBalanceIncrease,
        uint256 _fromIndex,
        uint256 _toIndex
    );

    event InterestStreamRedirected(
        address indexed _from,
        address indexed _to,
        uint256 _redirectedBalance,
        uint256 _fromBalanceIncrease,
        uint256 _fromIndex
    );

    event RedirectedBalanceUpdated(
        address indexed _targetAddress,
        uint256 _targetBalanceIncrease,
        uint256 _targetIndex,
        uint256 _redirectedBalanceAdded,
        uint256 _redirectedBalanceRemoved
    );

    address public underlyingAssetAddress;
    uint8 public underlyingAssetDecimals;

    mapping (address => uint256) private userIndexes;

    LendingPoolAddressesProvider private addressesProvider;
    LendingPoolCore private core;
    LendingPool private pool;
    LendingPoolDataProvider private dataProvider;

    modifier onlyLendingPool {
        require (msg.sender == address(pool), "The caller of this function must be a lending pool");
        _;
    }

    modifier whenTransferAllowed(address _from, uint256 _amount) {
        require(isTransferAllowed(_from, _amount));
        _;
    }

    constructor(
        LendingPoolAddressesProvider _addressesProvider,
        address _underlyingAsset,
        uint8 _underlyingAssetDecimals,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        addressesProvider = _addressesProvider;
        core = LendingPoolCore(payable(addressesProvider.getLendingPoolCore()));
        pool = LendingPool(addressesProvider.getLendingPool());
        dataProvider = LendingPoolDataProvider(addressesProvider.getLendingPoolDataProvider());
        underlyingAssetDecimals = _underlyingAssetDecimals;
        underlyingAssetAddress = _underlyingAsset;
    }

    function decimals() public view override returns(uint8){
        return underlyingAssetDecimals;
    }

    function _transfer(address _from, address _to, uint256 _amount) 
        internal 
        override 
        whenTransferAllowed(_from, _amount)
    {
        executeTransferInternal(_from, _to, _amount);
    }


    function redeem(uint256 _amount) external {
        
        require(_amount > 0, "Amount to redeem needs to be greater than zero");

        (
            ,
            uint256 currentBalance,
            uint256 balanceIncrease,
            uint256 index 
        ) = cumulateBalanceInternal(msg.sender);

        uint256 amountToRedeem = _amount;

        if(_amount == UINT_MAX_VALUE) {
            amountToRedeem = currentBalance;
        }

        require(amountToRedeem <= currentBalance, "User cannot redeem more than the available balance");

        require(isTransferAllowed(msg.sender, amountToRedeem), "Transfer cannot be allowed");

        //if the user is redirecting his interest towards someone else,
        //we update the redirected balance of the redirection address by adding the accrued interest,
        //and removing the amount to redeem
        // updateRedirectedBalanceOfRedirectionAddressInternal(msg.sender, balanceIncrease, amountToRedeem);
        
        _burn(msg.sender, amountToRedeem);

        bool userIndexReset = false;

        if(currentBalance.sub(amountToRedeem) == 0) {
            userIndexReset = resetDataOnZeroBalanceInternal(msg.sender);
        }

        pool.redeemUnderlying(
            underlyingAssetAddress,
            payable(msg.sender),
            amountToRedeem,
            currentBalance.sub(amountToRedeem)
        );

        emit Redeem(msg.sender, amountToRedeem, balanceIncrease, userIndexReset ? 0 : index);
    }

    function mintOnDeposit(address _account, uint256 _amount) external onlyLendingPool {

        (
            ,
            ,
            uint256 balanceIncrease,
            uint256 index 
        ) = cumulateBalanceInternal(_account);
        
        //if the user is redirecting his interest towards someone else,
        //we update the redirected balance of the redirection address by adding the accrued interest
        //and the amount deposited
        // updateRedirectedBalanceOfRedirectionAddressInternal(_account, balanceIncrease.add(_amount), 0);
        
        _mint(_account, _amount);

        emit MintOnDeposit(_account, _amount, balanceIncrease, index);
    }

    function burnOnLiquidation(address _account, uint256 _value) external onlyLendingPool {

        (
            ,
            uint256 accountBalance,
            uint256 balanceIncrease,
            uint256 index
        ) = cumulateBalanceInternal(_account);

        //adds the accrued interest and substracts the burned amount to
        //the redirected balance
        // updateRedirectedBalanceOfRedirectionAddressInternal(_account, balanceIncrease, _value);

        _burn(_account, _value);

        bool userIndexReset = false;

        if(accountBalance.sub(_value) == 0) {
            userIndexReset = resetDataOnZeroBalanceInternal(_account);
        }

        emit BurnOnLiquidation(_account, _value, balanceIncrease, userIndexReset ? 0 : index);
    }

    //transferOnLiquidation
    function transferOnLiquidation(address _from, address _to, uint256 _value) external onlyLendingPool {
        executeTransferInternal(_from, _to, _value);
    }

    function principalBalanceOf(address _user) external view returns(uint256) {
        return super.balanceOf(_user);
    }

    function totalSupply() public override view returns(uint256) {
        
        uint256 currentSupplyPrincipal = super.totalSupply();

        if(currentSupplyPrincipal == 0) {
            return 0;
        }

        return currentSupplyPrincipal
            .wadToRay()
            .rayMul(core.getReserveNormalizedIncome(underlyingAssetAddress))
            .rayToWad();
    }

    function isTransferAllowed(address _user, uint256 _amount) public view returns (bool) {
        return dataProvider.balanceDecreaseAllowed(underlyingAssetAddress, _user, _amount);
    }

    function getUserIndex(address _user) external view returns(uint256) {
        return userIndexes[_user];
    }


    function cumulateBalanceInternal(address _user)
        internal
        returns(uint256, uint256, uint256, uint256)
    {
        uint256 previousPrincipalBalance = super.balanceOf(_user);

        //calculate the accrued interest since the last accumulation
        uint256 balanceIncrease = balanceOf(_user).sub(previousPrincipalBalance);
        //mints an amount of tokens equivalent to the amount accumulated
        _mint(_user, balanceIncrease);
        //updates the user index
        uint256 index = userIndexes[_user] = core.getReserveNormalizedIncome(underlyingAssetAddress);
        return (
            previousPrincipalBalance,
            previousPrincipalBalance.add(balanceIncrease),
            balanceIncrease,
            index
        );
    }    

    function calculateCumulatedBalanceInternal(
        address _user,
        uint256 _balance
    ) internal view returns (uint256) {
        return _balance
            .wadToRay()
            .rayMul(core.getReserveNormalizedIncome(underlyingAssetAddress))
            .rayDiv(userIndexes[_user])
            .rayToWad();
    }

    function executeTransferInternal(
        address _from,
        address _to,
        uint256 _value
    ) internal {
        require(_value > 0, "Transferred amount needs to be greater than zero");

        //cumulate the balance of the sender
        (
            ,
            uint256 fromBalance,
            uint256 fromBalanceIncrease,
            uint256 fromIndex
        ) = cumulateBalanceInternal(_from);

        //cumulate the balance of the receiver
        (
            ,
            ,
            uint256 toBalanceIncrease,
            uint256 toIndex
        ) = cumulateBalanceInternal(_to);

        //if the sender is redirecting his interest towards someone else,
        //adds to the redirected balance the accrued interest and removes the amount
        //being transferred
        // updateRedirectedBalanceOfRedirectionAddressInternal(_from, fromBalanceIncrease, _value);

        //if the receiver is redirecting his interest towards someone else,
        //adds to the redirected balance the accrued interest and the amount
        //being transferred
        // updateRedirectedBalanceOfRedirectionAddressInternal(_to, toBalanceIncrease.add(_value), 0);

        //performs the transfer
        super._transfer(_from, _to, _value);

        bool fromIndexReset = false;
        //reset the user data if the remaining balance is 0
        if(fromBalance.sub(_value) == 0) {
            fromIndexReset = resetDataOnZeroBalanceInternal(_from);
        }

        emit BalanceTransfer(
            _from,
            _to,
            _value,
            fromBalanceIncrease,
            toBalanceIncrease,
            fromIndexReset ? 0 : fromIndex,
            toIndex
        );
    }

    function resetDataOnZeroBalanceInternal(address _user) internal returns(bool) {
        userIndexes[_user] = 0;
        return true;
    }
}