//SPDX-License-Identifier:MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TokenDistributor is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Distribution {
        address[] receivers;
        uint256[] percentages;
    }

    event DistributionUpdate(address[] receivers, uint256[] percentages);
    event Distributed(address reveiver, uint256 percentage, uint256 amount);

    uint256 public constant MAX_UINT = type(uint256).max;

    uint256 public constant MAX_UINT_MINUS_ONE = type(uint256).max - 1;

    uint256 public constant MIN_CONVERSION_RATE = 1;

    address public constant ETH_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    Distribution private distribution;

    uint256 public constant DISTRIBUTION_BASE = 10000;

    address public tokenToBurn;

    address public recipientBurn;

    function initialize(address[] memory _receivers, uint256[] memory _percentages) public {
        internalSetTokenDistribution(_receivers, _percentages);// percentage express in x/10000
        
    }

    fallback() external payable {}

    function distribute(IERC20[] memory _tokens) public {
        for(uint256 i = 0; i < _tokens.length; i++) {
            uint256 _balanceToDistribute = (address(_tokens[i])) != ETH_ADDRESS
                ? _tokens[i].balanceOf(address(this))
                : address(this).balance;
            
            if(_balanceToDistribute <= 0) {
                continue;
            }
            internalDistributeTokenWithAmount(_tokens[i], _balanceToDistribute);
        }
    }

    function distributeWithAmount(IERC20[] memory _tokens, uint256[] memory _amounts) public {
        require(_tokens.length == _amounts.length, "Array lengths should be equal");
        
        for(uint256 i = 0; i < _tokens.length; i++) {
            internalDistributeTokenWithAmount(_tokens[i], _amounts[i]);
        }
    }

    function distributeWithPercentage(IERC20[] memory _tokens, uint256[] memory _percentages) public {
        require(_tokens.length == _percentages.length, "Array lengths should be equal");
        
        for(uint256 i = 0; i < _tokens.length; i++) {
            uint256 _amountToDistribute = (address(_tokens[i]) != ETH_ADDRESS)
                ? _tokens[i].balanceOf(address(this)).mul(_percentages[i]).div(100)
                : address(this).balance.mul(_percentages[i]).div(100);
            if(_amountToDistribute <= 0) {
                continue;
            }

            internalDistributeTokenWithAmount(_tokens[i], _amountToDistribute);
        }
    }

    function internalSetTokenDistribution(address[] memory _receivers, uint256[] memory _percentages) internal {
        require(_receivers.length == _percentages.length, "Array lengths should be equal");

        distribution = Distribution({receivers: _receivers, percentages: _percentages});
        emit DistributionUpdate(_receivers, _percentages);
    }

    function internalDistributeTokenWithAmount(IERC20 _token, uint256 _amountToDistribute) internal {
        address _tokenAddress = address(_token);
        Distribution memory _distribution = distribution;

        for(uint256 i = 0; i < _distribution.receivers.length; i++) {
            uint256 _amount = _amountToDistribute.mul(_distribution.percentages[i]).div(DISTRIBUTION_BASE);

            if(_amount == 0) {
                continue;
            }

            if(_tokenAddress != ETH_ADDRESS) {
                _token.safeTransfer(_distribution.receivers[i], _amount);
            } else {
                (bool success, ) = _distribution.receivers[i].call{value: _amount}("");
                require(success, "Reverted ETH tranfer");
            }

            emit Distributed(_distribution.receivers[i], _distribution.percentages[i], _amount);
        }
    }

    function getDistribution() public view returns (
        address[] memory receivers,
        uint256[] memory percentages
    ) {
        receivers = distribution.receivers;
        percentages = distribution.percentages;
    }
}