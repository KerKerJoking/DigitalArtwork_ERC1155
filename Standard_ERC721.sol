// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract Standard_ERC721 is ERC721 {
    uint256 public nextTokenId;

    constructor() ERC721("Standard ERC721", "SERC721") {}

    // Simple mint function to mint a token with an auto-incremented ID
    function mint() external {
        _safeMint(msg.sender, nextTokenId);
        nextTokenId++;
    }
}
