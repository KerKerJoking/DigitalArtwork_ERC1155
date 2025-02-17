// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// 引入 OpenZeppelin 標準庫
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract DigitalArtwork is ERC1155, AccessControl, ReentrancyGuard {
    // 定義角色
    bytes32 public constant ARTIST_ROLE = keccak256("ARTIST_ROLE");
    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");

    // ARTcoin 的 token id（同質化代幣）
    uint256 public constant ARTCOIN_ID = 0;
    // Artwork 模板的 tokenId 由 1 開始累計
    uint256 public currentArtworkId;

    // 用戶（例如 Customer 與 Arbitrator）在鏈上登記的公鑰（如有需要）
    mapping(address => bytes) public publicKeys;

    // =====================================================
    // Artwork 與 Purchase 的資料結構
    // =====================================================

    // Artwork 模板（不再記錄 buyer 與狀態）
    struct Artwork {
        uint256 tokenId;       // 作品 NFT 的 token id
        string name;           // 作品名稱
        string hash_json;      // 詳細資料 JSON 的 IPFS 地址
        uint256 supplyLimit;   // 發行量上限
        uint256 minted;        // 已鑄造數量（用以檢查供應量上限）
        uint256 price;         // 售價（以 ARTcoin 計）
        address artist;        // 藝術家地址
    }

    // 每筆購買的狀態列舉
    enum PurchaseState { Active, Disputed, Resolved, Refunded }

    // 每筆購買記錄
    struct Purchase {
        address buyer;         // 購買者地址
        PurchaseState state;   // 該筆購買的狀態
        uint256 lockedDeposit; // 該次購買所鎖定的押金（通常為 2 倍售價）
    }

    // artwork tokenId 對應 Artwork 模板
    mapping(uint256 => Artwork) public artworks;
    // artwork tokenId 對應多筆購買記錄
    mapping(uint256 => Purchase[]) public artworkPurchases;

    // =====================================================
    // Artist 押金池
    // =====================================================

    // 全域記錄每個 Artist 的押金（來自 depositArtcoin 與 NFT 銷售收益）
    mapping(address => uint256) public artistDeposits;

    // =====================================================
    // 事件定義
    // =====================================================

    event ArtworkCreated(uint256 indexed tokenId, address indexed artist, uint256 price, uint256 supplyLimit);
    event DepositArtcoin(address indexed artist, uint256 amount);
    event WithdrawArtcoin(address indexed artist, uint256 amount);
    event ArtworkMinted(uint256 indexed tokenId, address indexed buyer);
    event VerificationResult(uint256 indexed tokenId, uint256 purchaseIndex, address indexed buyer, bool result);
    event DisputeOpened(uint256 indexed tokenId, uint256 purchaseIndex, address indexed buyer);
    event DisputeSettled(uint256 indexed tokenId, uint256 purchaseIndex, bool disputeResult);
    event FundsDistributed(uint256 indexed tokenId, uint256 purchaseIndex, address indexed artist, address indexed buyer, uint256 saleNet);
    event NFTBurned(uint256 indexed tokenId, uint256 purchaseIndex, address indexed buyer);
    event PublicKeyUpdated(address indexed account, bytes publicKey);

    // =====================================================
    // 建構子與 supportsInterface
    // =====================================================

    constructor(string memory uri) ERC1155(uri) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
    
    // Override supportsInterface to include ERC1155 and AccessControl interfaces
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // =====================================================
    // 1. ARTcoin 功能（本合約內部的 ERC1155 同質化代幣）
    // =====================================================

    /// @notice 由合約管理者（admin）增發 ARTcoin 給指定地址
    function mintARTcoin(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _mint(to, ARTCOIN_ID, amount, "");
    }

    // =====================================================
    // 2. Artist 押金管理（全域押金池）
    // =====================================================

    /// @notice Artist 存入 ARTcoin 作為全域押金（供多次作品發行使用）
    function depositArtcoin(uint256 amount) external nonReentrant {
        // 從 Artist 帳戶轉移 ARTcoin 至合約地址
        safeTransferFrom(msg.sender, address(this), ARTCOIN_ID, amount, "");
        artistDeposits[msg.sender] += amount;
        emit DepositArtcoin(msg.sender, amount);
    }

    /// @notice Artist 提領其可用的押金（注意：鎖定中的押金不可提領）
    function withdrawArtcoin(uint256 amount) external nonReentrant {
        require(artistDeposits[msg.sender] >= amount, "Insufficient deposit");
        artistDeposits[msg.sender] -= amount;
        _safeTransferFrom(address(this), msg.sender, ARTCOIN_ID, amount, "");
        emit WithdrawArtcoin(msg.sender, amount);
    }

    // =====================================================
    // 3. Artwork 創建
    // =====================================================

    /// @notice 由經授權的 Artist 建立 Artwork 模板
    function createArtwork(
        string memory _name,
        string memory _hash_json,
        uint256 _supplyLimit,  // 例如：限量發行
        uint256 _price         // 售價（ARTcoin 數量）
    ) external onlyRole(ARTIST_ROLE) returns (uint256) {
        currentArtworkId++;
        uint256 tokenId = currentArtworkId;
        artworks[tokenId] = Artwork({
            tokenId: tokenId,
            name: _name,
            hash_json: _hash_json,
            supplyLimit: _supplyLimit,
            minted: 0,
            price: _price,
            artist: msg.sender
        });
        emit ArtworkCreated(tokenId, msg.sender, _price, _supplyLimit);
        return tokenId;
    }

    // =====================================================
    // 4. NFT 購買與押金鎖定（支援多筆購買）
    // =====================================================

    /// @notice Customer 購買（鑄造）該 Artwork NFT，需支付 2 倍售價  
    /// 同時從該 Artwork 所屬 Artist 的全域押金中扣除相同金額作鎖定，記錄在該筆購買中
    function mintArtwork(uint256 _tokenId) external nonReentrant {
        Artwork storage art = artworks[_tokenId];
        require(art.minted < art.supplyLimit, "All NFTs minted");
        uint256 requiredAmount = art.price * 2;  // Customer 支付 2 倍價格

        // Customer 將 2 倍售價轉入合約
        safeTransferFrom(msg.sender, address(this), ARTCOIN_ID, requiredAmount, "");

        // 檢查並扣除該 Artwork 所屬 Artist 的全域押金（鎖定用）
        require(artistDeposits[art.artist] >= requiredAmount, "Artist deposit insufficient");
        artistDeposits[art.artist] -= requiredAmount;

        // 建立一筆新的購買記錄
        Purchase memory newPurchase = Purchase({
            buyer: msg.sender,
            state: PurchaseState.Active,
            lockedDeposit: requiredAmount
        });
        artworkPurchases[_tokenId].push(newPurchase);

        art.minted += 1;
        // 鑄造 NFT 至買家（ERC1155 可用同一 tokenId 多次發行）
        _mint(msg.sender, _tokenId, 1, "");
        emit ArtworkMinted(_tokenId, msg.sender);
    }

    // =====================================================
    // 5. 客戶驗證與款項分配（針對單筆購買）
    // =====================================================

    /// @notice Customer 驗證下載內容後回報結果
    /// 若驗證成功：退還 Buyer art.price，使其實際支付 art.price，並將鎖定押金與 art.price 累入 Artist 押金池
    /// 若驗證失敗：進入爭議流程
    function verifyPurchase(uint256 _tokenId, uint256 purchaseIndex, bool verificationResult) external nonReentrant {
        require(purchaseIndex < artworkPurchases[_tokenId].length, "Invalid purchase index");
        Purchase storage purchase = artworkPurchases[_tokenId][purchaseIndex];
        require(purchase.buyer == msg.sender, "Caller is not the buyer");
        require(purchase.state == PurchaseState.Active, "Purchase not active");

        Artwork storage art = artworks[_tokenId];
        emit VerificationResult(_tokenId, purchaseIndex, msg.sender, verificationResult);
        
        if (verificationResult) {
            // 驗證成功：退還 Buyer art.price (2x paid - art.price refund)
            _safeTransferFrom(address(this), msg.sender, ARTCOIN_ID, art.price, "");
            // 將原本鎖定的押金加上銷售收益 art.price 累入 Artist 的押金池
            artistDeposits[art.artist] += (purchase.lockedDeposit + art.price);
            purchase.lockedDeposit = 0;
            purchase.state = PurchaseState.Resolved;
            emit FundsDistributed(_tokenId, purchaseIndex, art.artist, msg.sender, art.price);
        } else {
            // 驗證失敗：進入爭議流程
            purchase.state = PurchaseState.Disputed;
            emit DisputeOpened(_tokenId, purchaseIndex, msg.sender);
        }
    }

    /// @notice 仲裁者對爭議進行判定  
    /// 若 disputeResult 為 true（作品正確），則流程同驗證成功；若為 false，則全額退還 Buyer 2 倍售價，並返還鎖定押金給 Artist，且銷毀 NFT
    function settlePurchaseDispute(uint256 _tokenId, uint256 purchaseIndex, bool disputeResult) external nonReentrant onlyRole(ARBITRATOR_ROLE) {
        require(purchaseIndex < artworkPurchases[_tokenId].length, "Invalid purchase index");
        Purchase storage purchase = artworkPurchases[_tokenId][purchaseIndex];
        require(purchase.state == PurchaseState.Disputed, "Purchase not in dispute");

        Artwork storage art = artworks[_tokenId];
        
        if (disputeResult) {
            // 仲裁認定作品正確：退還 Buyer art.price，將鎖定押金與銷售收益累入 Artist 押金池
            _safeTransferFrom(address(this), purchase.buyer, ARTCOIN_ID, art.price, "");
            artistDeposits[art.artist] += (purchase.lockedDeposit + art.price);
            purchase.lockedDeposit = 0;
            purchase.state = PurchaseState.Resolved;
            emit FundsDistributed(_tokenId, purchaseIndex, art.artist, purchase.buyer, art.price);
        } else {
            // 仲裁認定作品有誤：全額退還 Buyer (2 倍售價)，並返還鎖定押金給 Artist，同時銷毀 NFT
            _safeTransferFrom(address(this), purchase.buyer, ARTCOIN_ID, art.price * 2, "");
            artistDeposits[art.artist] += purchase.lockedDeposit;
            purchase.lockedDeposit = 0;
            purchase.state = PurchaseState.Refunded;
            _burn(purchase.buyer, _tokenId, 1);
            emit NFTBurned(_tokenId, purchaseIndex, purchase.buyer);
        }
        emit DisputeSettled(_tokenId, purchaseIndex, disputeResult);
    }

    // =====================================================
    // 6. 輔助查詢函數
    // =====================================================

    /// @notice 查詢指定 tokenId 的 Artwork 資訊
    function getArtworkInfo(uint256 _tokenId) external view returns (Artwork memory) {
        return artworks[_tokenId];
    }

    /// @notice 查詢指定 artwork 的某筆購買資訊
    function getPurchaseInfo(uint256 _tokenId, uint256 purchaseIndex) external view returns (Purchase memory) {
        require(purchaseIndex < artworkPurchases[_tokenId].length, "Invalid purchase index");
        return artworkPurchases[_tokenId][purchaseIndex];
    }
}
