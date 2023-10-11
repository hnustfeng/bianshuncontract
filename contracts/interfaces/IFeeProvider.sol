/*
 * @Description: 
 * @Author: Martin
 * @Date: 2023-02-20 11:03:36
 * @LastEditors: Martin
 * @LastEditTime: 2023-02-20 11:05:26
 */
//SPDX-License-Identifier:MIT
pragma solidity ^0.8.9;

interface IFeeProvider {
    function calculateLoanOriginationFee(address _user, uint256 _amount) external view returns (uint256);
    function getLoanOriginationFeePercentage() external view returns (uint256);
}