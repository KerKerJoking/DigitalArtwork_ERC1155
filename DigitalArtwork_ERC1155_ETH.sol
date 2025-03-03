// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol"; 
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract DigitalArtwork_ERC1155_ETH is ERC1155, ERC1155Holder, AccessControl, ReentrancyGuard {
    // Roles
    bytes32 public constant ARTIST_ROLE = keccak256("ARTIST_ROLE");
    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");

    uint256 public currentArtworkId;
    // Timeout period for buyer confirmation (e.g., 10 minutes)
    uint256 public constant CONFIRMATION_TIMEOUT = 10 minutes;

    // Artwork structure
    struct Artwork {
        uint256 tokenId;
        string name;
        string hash_json;
        uint256 supplyLimit;
        uint256 minted;
        uint256 price; // Price per artwork in wei
        address artist;
    }

    // Purchase state
    enum PurchaseState { Active, Disputed, Resolved, Refunded }

    // Purchase record structure
    struct Purchase {
        address buyer;
        PurchaseState state;
        uint256 lockedDeposit; // Amount locked from artist's deposit for this purchase
        uint256 purchaseTime;
    }

    mapping(uint256 => Artwork) public artworks;
    mapping(uint256 => Purchase[]) public artworkPurchases;
    // Artist deposit (in ETH)
    mapping(address => uint256) public artistDeposits;

    // Events
    event ArtworkCreated(uint256 indexed tokenId, address indexed artist, uint256 price, uint256 supplyLimit);
    event ArtworkMinted(uint256 indexed tokenId, uint256 purchaseIndex, address indexed buyer);
    event FundsDistributed(uint256 indexed tokenId, uint256 purchaseIndex, address indexed artist, address indexed buyer, uint256 saleNet);
    event PurchaseVerified(uint256 indexed tokenId, uint256 purchaseIndex, address indexed buyer, bool verified);
    event DisputeForced(uint256 indexed tokenId, uint256 purchaseIndex, address indexed artist);
    event DisputeSettled(uint256 indexed tokenId, uint256 purchaseIndex, bool disputeResult);
    event DepositETH(address indexed artist, uint256 amount);
    event WithdrawETH(address indexed artist, uint256 amount);

    constructor(string memory uri) ERC1155(uri) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
    
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, ERC1155Holder, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // Artists deposit ETH as collateral.
    function depositETH() external payable nonReentrant {
        require(msg.value > 0, "Must deposit positive ETH");
        artistDeposits[msg.sender] += msg.value;
        emit DepositETH(msg.sender, msg.value);
    }

    // Artists can withdraw their deposited ETH.
    function withdrawETH(uint256 amount) external nonReentrant {
        require(artistDeposits[msg.sender] >= amount, "Insufficient deposit");
        artistDeposits[msg.sender] -= amount;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdrawal failed");
        emit WithdrawETH(msg.sender, amount);
    }

    // Artists create an artwork template.
    function createArtwork(
        string memory _name,
        string memory _hash_json,
        uint256 _supplyLimit,
        uint256 _price
    ) external onlyRole(ARTIST_ROLE) returns (uint256) {
        currentArtworkId++;
        uint256 tokenId = currentArtworkId;
        artworks[tokenId] = Artwork({
            tokenId: tokenId,
            name: _name,
            hash_json: _hash_json,
            supplyLimit: _supplyLimit,
            minted: 0,
            price: _price, // Price in wei
            artist: msg.sender
        });
        emit ArtworkCreated(tokenId, msg.sender, _price, _supplyLimit);
        return tokenId;
    }

    // Customers purchase (mint) an artwork NFT by sending exactly 2x the artwork's price in ETH.
    function mintArtwork(uint256 _tokenId) external payable nonReentrant {
        Artwork storage art = artworks[_tokenId];
        require(art.minted < art.supplyLimit, "All NFTs minted");
        uint256 requiredAmount = art.price * 2;
        require(msg.value == requiredAmount, "Incorrect ETH amount sent");
        require(artistDeposits[art.artist] >= requiredAmount, "Artist deposit insufficient");
        artistDeposits[art.artist] -= requiredAmount;

        Purchase memory newPurchase = Purchase({
            buyer: msg.sender,
            state: PurchaseState.Active,
            lockedDeposit: requiredAmount,
            purchaseTime: block.timestamp
        });
        artworkPurchases[_tokenId].push(newPurchase);
        uint256 purchaseIndex = artworkPurchases[_tokenId].length - 1;

        art.minted += 1;
        _mint(msg.sender, _tokenId, 1, "");
        emit ArtworkMinted(_tokenId, purchaseIndex, msg.sender);
    }

    // Buyers verify the purchase outcome.
    // If verification passes: refund buyer art.price in ETH and add (lockedDeposit + art.price) to artist deposit.
    function verifyPurchase(uint256 _tokenId, uint256 purchaseIndex, bool verificationResult) external nonReentrant {
        require(purchaseIndex < artworkPurchases[_tokenId].length, "Invalid purchase index");
        Purchase storage purchase = artworkPurchases[_tokenId][purchaseIndex];
        require(purchase.buyer == msg.sender, "Caller not buyer");
        require(purchase.state == PurchaseState.Active, "Purchase not active");

        Artwork storage art = artworks[_tokenId];
        if (verificationResult) {
            (bool success, ) = payable(msg.sender).call{value: art.price}("");
            require(success, "Refund failed");
            artistDeposits[art.artist] += (purchase.lockedDeposit + art.price);
            purchase.lockedDeposit = 0;
            purchase.state = PurchaseState.Resolved;
            emit FundsDistributed(_tokenId, purchaseIndex, art.artist, msg.sender, art.price);
        } else {
            purchase.state = PurchaseState.Disputed;
        }
        emit PurchaseVerified(_tokenId, purchaseIndex, msg.sender, verificationResult);
    }

    // If the buyer does not confirm within the timeout, the artist can force confirmation.
    function forceConfirmPurchase(uint256 _tokenId, uint256 purchaseIndex) external nonReentrant {
        Artwork storage art = artworks[_tokenId];
        require(msg.sender == art.artist, "Only artist can force confirm");
        require(purchaseIndex < artworkPurchases[_tokenId].length, "Invalid purchase index");
        Purchase storage purchase = artworkPurchases[_tokenId][purchaseIndex];
        require(purchase.state == PurchaseState.Active, "Purchase not active");
        require(block.timestamp >= purchase.purchaseTime + CONFIRMATION_TIMEOUT, "Timeout not reached");

        (bool success, ) = payable(purchase.buyer).call{value: art.price}("");
        require(success, "Refund failed");
        artistDeposits[art.artist] += (purchase.lockedDeposit + art.price);
        purchase.lockedDeposit = 0;
        purchase.state = PurchaseState.Resolved;
        emit FundsDistributed(_tokenId, purchaseIndex, art.artist, purchase.buyer, art.price);
        emit DisputeForced(_tokenId, purchaseIndex, msg.sender);
    }
    
    // Arbitrator settles a disputed purchase.
    // If disputeResult is true, treat as verification success; otherwise, refund buyer full (2x price) and burn the NFT.
    function settlePurchaseDispute(uint256 _tokenId, uint256 purchaseIndex, bool disputeResult) external nonReentrant onlyRole(ARBITRATOR_ROLE) {
        require(purchaseIndex < artworkPurchases[_tokenId].length, "Invalid purchase index");
        Purchase storage purchase = artworkPurchases[_tokenId][purchaseIndex];
        require(purchase.state == PurchaseState.Disputed, "Purchase not in dispute");

        Artwork storage art = artworks[_tokenId];
        if (disputeResult) {
            (bool success, ) = payable(purchase.buyer).call{value: art.price}("");
            require(success, "Refund failed");
            artistDeposits[art.artist] += (purchase.lockedDeposit + art.price);
            purchase.lockedDeposit = 0;
            purchase.state = PurchaseState.Resolved;
            emit FundsDistributed(_tokenId, purchaseIndex, art.artist, purchase.buyer, art.price);
        } else {
            (bool success, ) = payable(purchase.buyer).call{value: art.price * 2}("");
            require(success, "Refund failed");
            artistDeposits[art.artist] += purchase.lockedDeposit;
            purchase.lockedDeposit = 0;
            purchase.state = PurchaseState.Refunded;
            _burn(purchase.buyer, _tokenId, 1);
        }
        emit DisputeSettled(_tokenId, purchaseIndex, disputeResult);
    }

    // Allow the contract to receive ETH.
    receive() external payable {}
    fallback() external payable {}
}
