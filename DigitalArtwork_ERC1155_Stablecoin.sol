// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// 引入 OpenZeppelin 標準庫
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol"; 
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DigitalArtwork_ERC1155_Stablecoin is ERC1155, ERC1155Holder, AccessControl, ReentrancyGuard {
    // 定義角色
    bytes32 public constant ARTIST_ROLE = keccak256("ARTIST_ROLE");
    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");
    // Key Server 地址定義
    address public keyServer;

    // Artwork 模板的 tokenId 由 1 開始累計
    uint256 public currentArtworkId;
    // 用戶超時未完成 Purchase 時間
    uint256 public constant CONFIRMATION_TIMEOUT = 10 minutes;
    // 引入對應的 Stablecoin 合約，該 stablecoin 遵循 ERC20 標準
    IERC20 public stableCoin;

    // =====================================================
    // Artwork 與 Purchase 的資料結構
    // =====================================================

    // Artwork 資料結構
    struct Artwork {
        uint256 tokenId;       // 作品 NFT 的 token id
        string name;           // 作品名稱
        string hash_json;      // 詳細資料 JSON 的 IPFS 地址
        uint256 supplyLimit;   // 發行量上限
        uint256 minted;        // 已鑄造數量（用以檢查供應量上限）
        uint256 price;         // 售價（以 stableCoin 計）
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

    event StableCoinAddressSet(address stableCoinAddress);
    event ArtworkCreated(uint256 indexed tokenId, address indexed artist, uint256 price, uint256 supplyLimit);
    event ArtworkMinted(uint256 indexed tokenId, uint256 purchaseIndex, address indexed buyer);
    event FundsDistributed(uint256 indexed tokenId, uint256 purchaseIndex, address indexed artist, address indexed buyer, uint256 saleNet);
    event VerificationResult(uint256 indexed tokenId, uint256 purchaseIndex, address indexed buyer, bool result);
    event DisputeForced(uint256 indexed tokenId, uint256 purchaseIndex, address indexed artist);
    event DisputeOpened(uint256 indexed tokenId, uint256 purchaseIndex, address indexed buyer);
    event DisputeSettled(uint256 indexed tokenId, uint256 purchaseIndex, bool disputeResult);
    event NFTBurned(uint256 indexed tokenId, uint256 purchaseIndex, address indexed buyer);
    event PublicKeyUpdated(address indexed account, bytes publicKey);
    event DepositStablecoin(address indexed artist, uint256 amount);
    event WithdrawStablecoin(address indexed artist, uint256 amount);

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
    
    // Override supportsInterface to include ERC1155 and AccessControl interfaces
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, ERC1155Holder, AccessControl) returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    
    // 設定綁定ERC20穩定幣合約地址
    function setStableCoinAddress(address _stableCoinAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stableCoin = IERC20(_stableCoinAddress);
        emit StableCoinAddressSet(_stableCoinAddress);
    }
    
    // =====================================================
    // Artist 押金管理（全域押金池）
    // =====================================================

    // Artist 存入 stablecoin 作為全域押金（供多次作品發行使用）
    function depositStablecoin(uint256 amount) external nonReentrant onlyRole(ARTIST_ROLE) {
        require(address(stableCoin) != address(0), "StableCoin not set");
        // 從 Artist 帳戶轉移 stablecoin 至合約地址（必須先 approve stableCoin 轉移權限給本合約）
        require(stableCoin.transferFrom(msg.sender, address(this), amount), "StableCoin transfer failed");
        artistDeposits[msg.sender] += amount;
        emit DepositStablecoin(msg.sender, amount);
    }

    // Artist 提領其可用的押金（注意：鎖定中的押金不可提領）
    function withdrawStablecoin(uint256 amount) external nonReentrant onlyRole(ARTIST_ROLE) {
        require(artistDeposits[msg.sender] >= amount, "Insufficient deposit");
        artistDeposits[msg.sender] -= amount;
        // 從合約地址轉移 stablecoin 至 Artist 帳戶
        require(stableCoin.transfer(msg.sender, amount), "StableCoin transfer failed");
        emit WithdrawStablecoin(msg.sender, amount);
    }

    // =====================================================
    // Artwork 創建
    // =====================================================

    function createArtwork( string memory _name, string memory _hash_json, uint256 _supplyLimit, uint256 _price) external onlyRole(ARTIST_ROLE) returns (uint256) {
        require(_price % 10 == 0, "Price must be divisible by 10");
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
    // NFT 購買與押金鎖定（支援多筆購買）
    // =====================================================

    // Customer 購買（鑄造）該 Artwork NFT，需支付 120% 售價  
    // 同時從該 Artwork 所屬 Artist 的全域押金中扣除 20% 售價金額作鎖定，記錄在該筆購買中
    function mintArtwork(uint256 _tokenId) external nonReentrant {
        Artwork storage art = artworks[_tokenId];
        require(art.minted < art.supplyLimit, "All NFTs minted");
        uint256 depositAmount = art.price * 2 / 10; // 押金為 20% 售價
        uint256 requiredAmount = art.price + depositAmount;  // Customer 支付 120% 售價        
        // 將 120% 售價 stableCoin 從 Customer 地址轉入合約地址
        require(stableCoin.transferFrom(msg.sender, address(this), requiredAmount), "StableCoin transfer failed");
        // 檢查並扣除該 Artwork 所屬 Artist 的全域押金（鎖定用）
        require(artistDeposits[art.artist] >= depositAmount, "Artist deposit insufficient");
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
        emit ArtworkMinted(_tokenId, purchaseIndex, msg.sender);
    }

    // =====================================================
    // 客戶驗證與款項分配（針對單筆購買）
    // =====================================================

    // Customer 驗證下載內容後回報結果
    function verifyPurchase(uint256 _tokenId, uint256 purchaseIndex, bool verificationResult) external nonReentrant {
        require(purchaseIndex < artworkPurchases[_tokenId].length, "Invalid purchase index");
        Purchase storage purchase = artworkPurchases[_tokenId][purchaseIndex];
        require(purchase.buyer == msg.sender, "Caller is not the buyer");
        require(purchase.state == PurchaseState.Active, "Purchase not active");
        Artwork storage art = artworks[_tokenId];
        emit VerificationResult(_tokenId, purchaseIndex, msg.sender, verificationResult);
        
        if (verificationResult) {
            // 驗證成功
            uint256 depositAmount = art.price * 2 / 10; // 押金為 20% 售價
            uint256 feeAmount = art.price / 10; // 手續費為 10% 售價
            // 退還 Customer 20% 售價
            require(stableCoin.transfer(msg.sender, depositAmount), "Refund failed");
            // 將 10% 售價作為手續費交給 Key Server
            require(stableCoin.transfer(keyServer, feeAmount), "Refund failed");
            // 將原本鎖定的押金加上銷售收益扣除手續費共 110% 售價累入 Artist 的押金池
            artistDeposits[art.artist] += (purchase.lockedDeposit + art.price - feeAmount);
            purchase.lockedDeposit = 0;
            purchase.state = PurchaseState.Resolved;
            emit FundsDistributed(_tokenId, purchaseIndex, art.artist, msg.sender, art.price);
        } else {
            // 驗證失敗：進入爭議仲裁流程
            purchase.state = PurchaseState.Disputed;
            emit DisputeOpened(_tokenId, purchaseIndex, msg.sender);
        }
    }

    // 如果 Customer 在超時期限內未確認，允許 artist 強制確認該筆購買
    function forceConfirmPurchase(uint256 _tokenId, uint256 purchaseIndex) external nonReentrant {
        Artwork storage art = artworks[_tokenId];
        require(msg.sender == art.artist, "Only artist can force confirm");
        require(purchaseIndex < artworkPurchases[_tokenId].length, "Invalid purchase index");
        Purchase storage purchase = artworkPurchases[_tokenId][purchaseIndex];
        require(purchase.state == PurchaseState.Active, "Purchase not active");
        require(block.timestamp >= purchase.purchaseTime + CONFIRMATION_TIMEOUT, "Timeout not reached");

        // 模擬 Customer 驗證成功的處理流程
        uint256 depositAmount = art.price * 2 / 10; // 押金為 20% 售價
        uint256 feeAmount = art.price / 10; // 手續費為 10% 售價
        // 退還 Customer 10% 售價(20% 售價押金扣除 10% 售價手續費)
        require(stableCoin.transfer(purchase.buyer, depositAmount - feeAmount), "Refund failed");
        // 將 10% 售價作為手續費交給 Key Server
        require(stableCoin.transfer(keyServer, feeAmount), "Refund failed");
        // 將原本鎖定的押金加上銷售收益共 120% 售價累入 Artist 的押金池
        artistDeposits[art.artist] += (purchase.lockedDeposit + art.price);
        purchase.lockedDeposit = 0;
        purchase.state = PurchaseState.Resolved;
        emit FundsDistributed(_tokenId, purchaseIndex, art.artist, purchase.buyer, art.price);
        emit DisputeForced(_tokenId, purchaseIndex, msg.sender);
    }
    
    // 仲裁者對爭議進行判定
    function settlePurchaseDispute(uint256 _tokenId, uint256 purchaseIndex, bool disputeResult) external nonReentrant onlyRole(ARBITRATOR_ROLE) {
        require(purchaseIndex < artworkPurchases[_tokenId].length, "Invalid purchase index");
        Purchase storage purchase = artworkPurchases[_tokenId][purchaseIndex];
        require(purchase.state == PurchaseState.Disputed, "Purchase not in dispute");
        Artwork storage art = artworks[_tokenId];
        uint256 depositAmount = art.price * 2 / 10; // 押金為 20% 售價
        uint256 feeAmount = art.price / 10; // 手續費為 10% 售價

        if (disputeResult) {
            // 仲裁認定作品正確，不退還 Customer 費用
            // 將 10% 售價作為手續費交給 Key Server
            require(stableCoin.transfer(keyServer, feeAmount), "Refund failed");
            // 將 10% 售價作為手續費交給 仲裁者
            require(stableCoin.transfer(msg.sender, feeAmount), "Refund failed");
            // 將原本鎖定的押金加上銷售收益共 120% 售價累入 Artist 的押金池
            artistDeposits[art.artist] += (purchase.lockedDeposit + art.price);
            purchase.lockedDeposit = 0;
            purchase.state = PurchaseState.Resolved;
            emit FundsDistributed(_tokenId, purchaseIndex, art.artist, purchase.buyer, art.price);
        } else {
            // 仲裁認定作品有誤
            // 全額退還 Customer (120% 售價)
            require(stableCoin.transfer(purchase.buyer, art.price + depositAmount), "Refund failed");
            // 將 10% 售價作為手續費交給 Key Server
            require(stableCoin.transfer(keyServer, feeAmount), "Refund failed");
            // 將 10% 售價作為手續費交給 仲裁者
            require(stableCoin.transfer(msg.sender, feeAmount), "Refund failed");
            // 不返還鎖定押金給 Artist
            purchase.lockedDeposit = 0;
            purchase.state = PurchaseState.Refunded;
            // 銷毀 NFT
            _burn(purchase.buyer, _tokenId, 1);
        }
        emit DisputeSettled(_tokenId, purchaseIndex, disputeResult);
    }

    // =====================================================
    // 輔助查詢函數
    // =====================================================

    // 查詢指定 tokenId 的 Artwork 資訊
    //function getArtworkInfo(uint256 _tokenId) external view returns (Artwork memory) {
    //    return artworks[_tokenId];
    //}

    // 查詢指定 artwork 的某筆購買資訊
    //function getPurchaseInfo(uint256 _tokenId, uint256 purchaseIndex) external view returns (Purchase memory) {
    //    require(purchaseIndex < artworkPurchases[_tokenId].length, "Invalid purchase index");
    //    return artworkPurchases[_tokenId][purchaseIndex];
    //}

}
