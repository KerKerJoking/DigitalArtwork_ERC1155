// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract Standart_ERC1155 is ERC1155 {
    uint256 public nextTokenId;

    // The URI uses a placeholder {id} to be replaced by the token id in hex format
    constructor() ERC1155("https://example.com/api/item/{id}.json") {}

    // Simple mint function to mint a token with a specified amount and auto-incremented id
    function mint(uint256 amount) external {
        _mint(msg.sender, nextTokenId, amount, "");
        nextTokenId++;
    }
}
