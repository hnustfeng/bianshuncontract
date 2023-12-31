 //SPDX-License-Identifier:MIT
 pragma solidity ^0.8.9;

 import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

 contract DAItest is ERC20 {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        _mint(msg.sender, 10 * 10 ** 18);
    }

    function mint(uint256 _amount) public payable {
        _mint(msg.sender, _amount);
    }
 }
