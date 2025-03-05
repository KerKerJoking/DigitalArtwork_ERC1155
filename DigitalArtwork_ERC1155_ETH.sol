// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// 引入 OpenZeppelin 標準庫
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol"; 
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract DigitalArtwork_ERC1155_ETH is ERC1155, ERC1155Holder, AccessControl, ReentrancyGuard {
    // 定義角色
    bytes32 public constant ARTIST_ROLE = keccak256("ARTIST_ROLE");
    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");
    // Key Server 地址定義
    address public keyServer;
    // Key Server URL 定義
    string public keyServerURL;
    // Artwork 模板的 tokenId 由 1 開始累計
    uint256 public currentArtworkId;
    // 用戶超時未完成 Purchase 時間
    uint256 public constant CONFIRMATION_TIMEOUT = 10 minutes;

    // 用戶（KeyServer、Customer、Artist、Arbitrator）在鏈上登記的公鑰URI
    mapping(address => string) public publicKeyURI;

    // Artwork 資料結構
    struct Artwork {
        uint256 tokenId;       // 作品 NFT 的 token id
        string name;           // 作品名稱
        string hash_json;      // 詳細資料 JSON 的 IPFS 地址
        uint256 supplyLimit;   // 發行量上限
        uint256 minted;        // 已鑄造數量（用以檢查供應量上限）
        uint256 price;         // 售價（以 wei 計）
        address artist;        // 藝術家地址
    }

    // 每筆購買的狀態列舉
    enum PurchaseState { Active, Disputed, Resolved, Refunded }

    // 每筆購買記錄
    struct Purchase {
        address buyer;         // 購買者地址
        PurchaseState state;   // 該筆購買的狀態
        uint256 lockedDeposit; // 該次購買所鎖定的押金（通常為 2 倍售價）
        uint256 purchaseTime; 
    }

    // artwork tokenId 對應 Artwork 模板
    mapping(uint256 => Artwork) public artworks;
    // artwork tokenId 對應多筆購買記錄
    mapping(uint256 => Purchase[]) public artworkPurchases;

    // 記錄每個 Artist 的押金（來自 depositArtcoin 與 NFT 銷售收益）
    mapping(address => uint256) public artistDeposits;

    // =====================================================
    // 事件定義
    // =====================================================

    event ArtworkCreated(uint256 indexed tokenId, address indexed artist, uint256 price, uint256 supplyLimit);
    event ArtworkMinted(uint256 indexed tokenId, uint256 indexed purchaseIndex, address indexed buyer, uint256 purchaseAmount, uint256 depositLocked);
    event FundsDistributed(uint256 indexed tokenId, uint256 indexed purchaseIndex, address indexed artist, address buyer, uint256 buyerRefund, uint256 keyServerFee, uint256 arbitratorFee, uint256 artistCredit);
    event VerificationResult(uint256 indexed tokenId, uint256 purchaseIndex, address indexed buyer, bool result);
    event DisputeForced(uint256 indexed tokenId, uint256 purchaseIndex, address indexed artist);
    event DisputeOpened(uint256 indexed tokenId, uint256 purchaseIndex, address indexed buyer);
    event DisputeSettled(uint256 indexed tokenId, uint256 purchaseIndex, bool disputeResult);
    event NFTBurned(uint256 indexed tokenId, uint256 purchaseIndex, address indexed buyer);

    // =====================================================
    // 建構子與 supportsInterface
    // =====================================================

    constructor(string memory uri) ERC1155(uri) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        //預設Key Server地址為合約部署者
        keyServer = msg.sender; 
    }

    // Key Server 地址設定
    function setKeyServer(address _keyServer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        keyServer = _keyServer;
    }

    function setKeyServerURL(string calldata newURL) external {
        require(msg.sender == keyServer, "OnlyKeyServer");
        keyServerURL = newURL;
    }
    
    // 任何地址設定存放RSA公鑰的URI
    function setPublicKeyURI(string memory keyURI) external {
        publicKeyURI[msg.sender] = keyURI;
    }

    // Override supportsInterface to include ERC1155 and AccessControl interfaces
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, ERC1155Holder, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // =====================================================
    // Artist 押金管理（全域押金池）
    // =====================================================

    // Artist 存入 ETH 作為全域押金（供多次作品發行使用）
    function depositETH() external payable nonReentrant onlyRole(ARTIST_ROLE) {
        require(msg.value > 0, "TransferFail");
        artistDeposits[msg.sender] += msg.value;
    }

    // Artist 提領其可用的押金（注意：鎖定中的押金不可提領）
    function withdrawETH(uint256 amount) external nonReentrant onlyRole(ARTIST_ROLE) {
        require(artistDeposits[msg.sender] >= amount, "Insufficient deposit");
        artistDeposits[msg.sender] -= amount;
        // 從合約地址轉移 ETH 至 Artist 帳戶
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "TransferFail");
    }

    // =====================================================
    // Artwork 創建
    // =====================================================

    function createArtwork(string memory _name, string memory _hash_json, uint256 _supplyLimit, uint256 _price) external onlyRole(ARTIST_ROLE) returns (uint256) {
        require(_price % 10 == 0, "InvalidPrice");
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

    // =====================================================
    // NFT 購買與押金鎖定（支援多筆購買）
    // =====================================================

    // Customer 購買（鑄造）該 Artwork NFT，需支付 120% 售價  
    // 同時從該 Artwork 所屬 Artist 的全域押金中扣除 20% 售價金額作鎖定，記錄在該筆購買中
    function mintArtwork(uint256 _tokenId) external payable nonReentrant {
        Artwork storage art = artworks[_tokenId];
        require(art.minted < art.supplyLimit, "SoldOut");
        uint256 depositAmount = art.price * 2 / 10; // 押金為 20% 售價
        uint256 requiredAmount = art.price + depositAmount;  // Customer 支付 120% 售價   
        // 檢查 Customer 地址轉入 ETH 數量是否正確
        require(msg.value == requiredAmount, "TransferFail");
        // 檢查並扣除該 Artwork 所屬 Artist 的全域押金（鎖定用）
        require(artistDeposits[art.artist] >= depositAmount, "NoDeposit");
        artistDeposits[art.artist] -= depositAmount;
        // 建立一筆新的購買記錄
        Purchase memory newPurchase = Purchase({
            buyer: msg.sender,
            state: PurchaseState.Active,
            lockedDeposit: depositAmount,
            purchaseTime: block.timestamp
        });
        artworkPurchases[_tokenId].push(newPurchase);
        uint256 purchaseIndex = artworkPurchases[_tokenId].length - 1;
        // 鑄造 NFT 至買家（ERC1155 可用同一 tokenId 多次發行）
        art.minted += 1;
        _mint(msg.sender, _tokenId, 1, "");
        emit ArtworkMinted(_tokenId, purchaseIndex, msg.sender, requiredAmount, depositAmount);
    }

    // =====================================================
    // 客戶驗證與款項分配（針對單筆購買）
    // =====================================================

    // Customer 驗證下載內容後回報結果
    function verifyPurchase(uint256 _tokenId, uint256 purchaseIndex, bool verificationResult) external nonReentrant {
        require(purchaseIndex < artworkPurchases[_tokenId].length, "InvalidIndex");
        Purchase storage purchase = artworkPurchases[_tokenId][purchaseIndex];
        require(purchase.buyer == msg.sender, "NotBuyer");
        require(purchase.state == PurchaseState.Active, "InactivePurchase");
        Artwork storage art = artworks[_tokenId];
        emit VerificationResult(_tokenId, purchaseIndex, msg.sender, verificationResult);

        if (verificationResult) {
            // 驗證成功
            uint256 depositAmount = art.price * 2 / 10; // 押金為 20% 售價
            uint256 feeAmount = art.price / 10; // 手續費為 10% 售價
            // 退還 Customer 20% 售價
            (bool successCustomer, ) = payable(msg.sender).call{value: depositAmount}("");
            require(successCustomer, "RefundFail");
            // 將 10% 售價作為手續費交給 Key Server
            (bool successKeyserver, ) = payable(keyServer).call{value: feeAmount}("");
            require(successKeyserver, "RefundFail");
            // 將原本鎖定的押金加上銷售收益扣除手續費共 110% 售價累入 Artist 的押金池
            artistDeposits[art.artist] += (purchase.lockedDeposit + art.price - feeAmount);
            purchase.lockedDeposit = 0;
            purchase.state = PurchaseState.Resolved;
            emit FundsDistributed(_tokenId, purchaseIndex, art.artist, msg.sender, depositAmount, feeAmount, 0, (purchase.lockedDeposit + art.price - feeAmount));
        } else {
            // 驗證失敗：進入爭議仲裁流程
            purchase.state = PurchaseState.Disputed;
            emit DisputeOpened(_tokenId, purchaseIndex, msg.sender);
        }
    }

    // 如果 Customer 在超時期限內未確認，允許 artist 強制確認該筆購買
    function forceConfirmPurchase(uint256 _tokenId, uint256 purchaseIndex) external nonReentrant {
        Artwork storage art = artworks[_tokenId];
        require(msg.sender == art.artist, "OnlyArtist");
        require(purchaseIndex < artworkPurchases[_tokenId].length, "InvalidIndex");
        Purchase storage purchase = artworkPurchases[_tokenId][purchaseIndex];
        require(purchase.state == PurchaseState.Active, "InactivePurchase");
        require(block.timestamp >= purchase.purchaseTime + CONFIRMATION_TIMEOUT, "TimeoutPending");

        // 模擬 Customer 驗證成功的處理流程
        uint256 depositAmount = art.price * 2 / 10; // 押金為 20% 售價
        uint256 feeAmount = art.price / 10; // 手續費為 10% 售價
        // 退還 Customer 10% 售價(20% 售價押金扣除 10% 售價手續費)
        (bool successCustomer, ) = payable(purchase.buyer).call{value: depositAmount - feeAmount}("");
        require(successCustomer, "RefundFail");
        // 將 10% 售價作為手續費交給 Key Server
        (bool successKeyserver, ) = payable(keyServer).call{value: feeAmount}("");
        require(successKeyserver, "RefundFail");
        // 將原本鎖定的押金加上銷售收益共 120% 售價累入 Artist 的押金池
        artistDeposits[art.artist] += (purchase.lockedDeposit + art.price);
        purchase.lockedDeposit = 0;
        purchase.state = PurchaseState.Resolved;
        emit FundsDistributed(_tokenId, purchaseIndex, art.artist, msg.sender, (depositAmount - feeAmount), feeAmount, 0, (purchase.lockedDeposit + art.price));
        emit DisputeForced(_tokenId, purchaseIndex, msg.sender);
    }
    
    // 仲裁者對爭議進行判定
    function settlePurchaseDispute(uint256 _tokenId, uint256 purchaseIndex, bool disputeResult) external nonReentrant onlyRole(ARBITRATOR_ROLE) {
        require(purchaseIndex < artworkPurchases[_tokenId].length, "InvalidIndex");
        Purchase storage purchase = artworkPurchases[_tokenId][purchaseIndex];
        require(purchase.state == PurchaseState.Disputed, "NotDisputed");
        Artwork storage art = artworks[_tokenId];
        uint256 depositAmount = art.price * 2 / 10; // 押金為 20% 售價
        uint256 feeAmount = art.price / 10; // 手續費為 10% 售價

        if (disputeResult) {
            // 仲裁認定作品正確，不退還 Customer 費用
            // 將 10% 售價作為手續費交給 Key Server
            (bool successKeyserver, ) = payable(keyServer).call{value: feeAmount}("");
            require(successKeyserver, "RefundFail");
            // 將 10% 售價作為手續費交給 Arbitrator
            (bool successArbitrator, ) = payable(keyServer).call{value: feeAmount}("");
            require(successArbitrator, "RefundFail");
            // 將原本鎖定的押金加上銷售收益共 120% 售價累入 Artist 的押金池
            artistDeposits[art.artist] += (purchase.lockedDeposit + art.price);
            purchase.lockedDeposit = 0;
            purchase.state = PurchaseState.Resolved;
            emit FundsDistributed(_tokenId, purchaseIndex, art.artist, purchase.buyer, 0, feeAmount, feeAmount, (purchase.lockedDeposit + art.price));
        } else {
            // 仲裁認定作品有誤
            // 全額退還 Customer (120% 售價)
            (bool successCustomer, ) = payable(purchase.buyer).call{value: art.price + depositAmount}("");
            require(successCustomer, "RefundFail");
            // 將 10% 售價作為手續費交給 Key Server
            (bool successKeyserver, ) = payable(keyServer).call{value: feeAmount}("");
            require(successKeyserver, "RefundFail");
            // 將 10% 售價作為手續費交給 Arbitrator
            (bool successArbitrator, ) = payable(keyServer).call{value: feeAmount}("");
            require(successArbitrator, "RefundFail");
            // 不返還鎖定押金給 Artist
            purchase.lockedDeposit = 0;
            purchase.state = PurchaseState.Refunded;
            // 銷毀 NFT
            _burn(purchase.buyer, _tokenId, 1);
            emit FundsDistributed(_tokenId, purchaseIndex, art.artist, purchase.buyer, (art.price + depositAmount), feeAmount, feeAmount, 0);
            emit NFTBurned(_tokenId, purchaseIndex, purchase.buyer);
        }
        emit DisputeSettled(_tokenId, purchaseIndex, disputeResult);
    }
    // 允許本合約接收 ETH.
    receive() external payable {}
    fallback() external payable {}
}
