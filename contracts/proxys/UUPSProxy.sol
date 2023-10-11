//SPDX-License-Identifier:MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract UUPSProxy is ERC1967Proxy {

    // address public owner;

    modifier onlyAdmin() {
        require(msg.sender == _getAdmin(), "You are not the admin");
        _;
    }

    constructor(address implementAddress) ERC1967Proxy(implementAddress, msg.data) {
        _changeAdmin(msg.sender);
    }

    function updateImpl(address newImpl) public onlyAdmin {
        _upgradeTo(newImpl);
    }

    function getImplementation() public view returns(address) {
        return _implementation();
    }

    function getAdmin() public view returns(address) {
        return _getAdmin();
    }
}