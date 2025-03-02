// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TestStableCoin is ERC20, Ownable {
    constructor() ERC20("Test Stable Coin", "TSC") Ownable(msg.sender) {
    }

    /// @notice 僅限合約管理者調用，增發指定數量的代幣給指定地址
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
