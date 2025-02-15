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
    // 作品 NFT 的 token id 從 1 開始累計
    uint256 public currentArtworkId;

    // 用戶（Customer 與 Arbitrator）在鏈上登記的公鑰
    mapping(address => bytes) public publicKeys;

    // 作品狀態列舉
    enum ArtworkState { Pending, Active, Disputed, Resolved, Refunded }

    // 作品結構（此處簡化設計：假設每件作品只賣一個 NFT）
    struct Artwork {
        uint256 tokenId;         // 作品 NFT 的 token id
        string name;             // 作品名稱
        bytes32 hash_artwork;    // 原始檔案 Hash
        string hash_thumb;       // 縮圖的 IPFS 地址
        string hash_json;        // 詳細資料 JSON 的 IPFS 地址
        uint256 supplyLimit;     // 發行量上限（可設為 1 以代表唯一作品）
        uint256 minted;          // 已鑄造數量
        uint256 price;           // 售價（以 ARTcoin 為單位）
        uint256 deposit;         // Artist 存入的押金（以 ARTcoin 計）
        address artist;          // 藝術家地址
        address buyer;           // 購買者地址（此設計假設每件作品僅有一筆購買）
        ArtworkState state;      // 作品當前狀態
    }

    // 作品資訊記錄：token id → Artwork
    mapping(uint256 => Artwork) public artworks;

    // 事件定義
    event ArtworkCreated(uint256 indexed tokenId, address indexed artist, uint256 price, uint256 supplyLimit);
    event DepositMade(uint256 indexed tokenId, address indexed artist, uint256 amount);
    event DepositWithdrawn(uint256 indexed tokenId, address indexed artist, uint256 amount);
    event ArtworkMinted(uint256 indexed tokenId, address indexed buyer);
    event VerificationResult(uint256 indexed tokenId, address indexed buyer, bool result);
    event DisputeOpened(uint256 indexed tokenId, address indexed buyer);
    event DisputeSettled(uint256 indexed tokenId, bool disputeResult);
    event FundsDistributed(uint256 indexed tokenId, address indexed artist, address indexed buyer, uint256 amount);
    event NFTBurned(uint256 indexed tokenId, address indexed buyer);
    event PublicKeyUpdated(address indexed account, bytes publicKey);

    constructor(string memory uri) ERC1155(uri) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // =====================================================
    // 1. 鏈上公鑰管理
    // =====================================================

    /// @notice 用戶（Customer、Arbitrator）登記或更新其公鑰資訊
    function setPublicKey(bytes calldata publicKey) external {
        publicKeys[msg.sender] = publicKey;
        emit PublicKeyUpdated(msg.sender, publicKey);
    }

    // =====================================================
    // 2. ARTcoin 功能（內建為 ERC1155 同質化代幣）
    // =====================================================

    /// @notice 由合約管理者（admin）增發 ARTcoin 給指定地址
    function mintARTcoin(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _mint(to, ARTCOIN_ID, amount, "");
    }

    // =====================================================
    // 3. 作品上傳、押金管理與 NFT 發行
    // =====================================================

    /// @notice 由經授權的 Artist 建立作品發行模板
    function createArtwork(
        string memory _name,
        bytes32 _hash_artwork,
        string memory _hash_thumb,
        string memory _hash_json,
        uint256 _supplyLimit,  // 可設 1 表示唯一作品
        uint256 _price         // 作品價格（ARTcoin 數量）
    ) external onlyRole(ARTIST_ROLE) returns (uint256) {
        currentArtworkId++;  // 作品 token id 從 1 開始
        uint256 tokenId = currentArtworkId;
        artworks[tokenId] = Artwork({
            tokenId: tokenId,
            name: _name,
            hash_artwork: _hash_artwork,
            hash_thumb: _hash_thumb,
            hash_json: _hash_json,
            supplyLimit: _supplyLimit,
            minted: 0,
            price: _price,
            deposit: 0,
            artist: msg.sender,
            buyer: address(0),
            state: ArtworkState.Pending
        });
        emit ArtworkCreated(tokenId, msg.sender, _price, _supplyLimit);
        return tokenId;
    }

    /// @notice Artist 為指定作品存入 ARTcoin 作為押金  
    /// 要求在呼叫前先將 ARTcoin 轉移權限授予合約（或直接透過此函數調用 safeTransferFrom）
    function depositForArtwork(uint256 _tokenId, uint256 amount) external nonReentrant {
        Artwork storage art = artworks[_tokenId];
        require(msg.sender == art.artist, "Only artist can deposit");
        // 從 artist 帳戶轉移 ARTcoin 到合約地址
        safeTransferFrom(msg.sender, address(this), ARTCOIN_ID, amount, "");
        art.deposit += amount;
        emit DepositMade(_tokenId, msg.sender, amount);
    }

    /// @notice Artist 提領部分押金，將合約內的 ARTcoin 退還給 artist
    function withdrawForArtwork(uint256 _tokenId, uint256 amount) external nonReentrant {
        Artwork storage art = artworks[_tokenId];
        require(msg.sender == art.artist, "Only artist can withdraw");
        require(art.deposit >= amount, "Insufficient deposit");
        art.deposit -= amount;
        // 從合約餘額轉出 ARTcoin 到 artist 地址
        _safeTransferFrom(address(this), msg.sender, ARTCOIN_ID, amount, "");
        emit DepositWithdrawn(_tokenId, msg.sender, amount);
    }

    /// @notice Customer 購買（鑄造）該作品 NFT，需支付 2 倍價格  
    /// 此範例假設每件作品僅有一次購買機會（若支援多份，需額外記錄每筆購買資訊）
    function mintArtwork(uint256 _tokenId) external nonReentrant {
        Artwork storage art = artworks[_tokenId];
        require(art.state == ArtworkState.Pending || art.state == ArtworkState.Active, "Artwork not available");
        require(art.minted < art.supplyLimit, "All NFTs minted");
        uint256 requiredAmount = art.price * 2;  // Customer 支付 2 倍價格
        // 從 Customer 帳戶轉移 ARTcoin 到合約
        safeTransferFrom(msg.sender, address(this), ARTCOIN_ID, requiredAmount, "");
        // 檢查 Artist 存入的押金是否足夠（至少應為 2 倍價格）
        require(art.deposit >= art.price * 2, "Artist deposit insufficient");
        art.minted += 1;
        art.buyer = msg.sender;  // 記錄購買者（假設唯一 NFT）
        // 鑄造 NFT 至購買者地址
        _mint(msg.sender, _tokenId, 1, "");
        art.state = ArtworkState.Active;
        emit ArtworkMinted(_tokenId, msg.sender);
    }

    // =====================================================
    // 4. 客戶驗證與款項分配
    // =====================================================

    /// @notice Customer 驗證下載並解密後的內容，回報驗證結果  
    /// 若驗證通過：退還價格的一倍給 Customer，並將該金額加入 Artist 押金  
    /// 若驗證失敗：進入爭議流程
    function verifyHash(uint256 _tokenId, bool verificationResult) external nonReentrant {
        Artwork storage art = artworks[_tokenId];
        require(art.buyer == msg.sender, "Caller is not the buyer");
        require(art.state == ArtworkState.Active, "Artwork not active");
        emit VerificationResult(_tokenId, msg.sender, verificationResult);
        if (verificationResult) {
            // 驗證成功：退還 Customer 一倍價格，並將該金額轉入 Artist 的押金（合約內部記帳）
            _safeTransferFrom(address(this), msg.sender, ARTCOIN_ID, art.price, "");
            art.deposit += art.price;
            art.state = ArtworkState.Resolved;
            emit FundsDistributed(_tokenId, art.artist, msg.sender, art.price);
        } else {
            // 驗證失敗：進入爭議流程
            art.state = ArtworkState.Disputed;
            emit DisputeOpened(_tokenId, msg.sender);
        }
    }

    // =====================================================
    // 5. 爭議仲裁流程（由仲裁者在鏈上操作）  
    // =====================================================

    /// @notice 仲裁者對爭議進行判定。  
    /// 若 disputeResult 為 true，視同驗證通過；若為 false，則雙方退款並銷毀 NFT。
    function settleDispute(uint256 _tokenId, bool disputeResult) external nonReentrant onlyRole(ARBITRATOR_ROLE) {
        Artwork storage art = artworks[_tokenId];
        require(art.state == ArtworkState.Disputed, "Artwork not in dispute");
        if (disputeResult) {
            // 仲裁結果認定作品無誤：退還 Customer 一倍價格，並將該金額加入 Artist 押金
            _safeTransferFrom(address(this), art.buyer, ARTCOIN_ID, art.price, "");
            art.deposit += art.price;
            art.state = ArtworkState.Resolved;
            emit FundsDistributed(_tokenId, art.artist, art.buyer, art.price);
        } else {
            // 仲裁結果認定作品有誤：退還 Customer 全額（2 倍價格），並退回 Artist 的全部押金，同時銷毀 NFT
            _safeTransferFrom(address(this), art.buyer, ARTCOIN_ID, art.price * 2, "");
            _safeTransferFrom(address(this), art.artist, ARTCOIN_ID, art.deposit, "");
            _burn(art.buyer, _tokenId, 1);
            art.state = ArtworkState.Refunded;
            emit NFTBurned(_tokenId, art.buyer);
        }
        emit DisputeSettled(_tokenId, disputeResult);
    }

    // =====================================================
    // 其他輔助查詢函數（選用）
    // =====================================================

    /// @notice 查詢指定 tokenId 的作品資訊
    function getArtworkInfo(uint256 _tokenId) external view returns (Artwork memory) {
        return artworks[_tokenId];
    }
}
