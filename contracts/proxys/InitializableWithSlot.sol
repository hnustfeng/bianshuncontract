//SPDX-License-Identifier:MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract InitializableWithSlot is Initializable {
    uint256[50] private ______gap;
}