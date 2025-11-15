// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ImpossibleDimensionMarket is ERC721URIStorage, ReentrancyGuard {
    uint256 private _tokenIds;
    uint256 private _itemsSold;

    address payable public owner;

    struct ListedToken {
        uint256 tokenId;
        address payable owner;   
        address payable seller;  // who listed it for sale (address(0) if not listed)
        uint256 price;
        bool currentlyListed;
    }

    // Struct to return tokenId + tokenURI together
    struct TokenInfo {
        uint256 tokenId;
        string tokenURI;
    }

    // Mapping tokenId => listing info
    mapping(uint256 => ListedToken) private idToListedToken;
    // Encrypted URI stored 
    mapping(uint256 => bytes) private encryptedTokenURI;
    mapping(uint256 => bytes32) private tokenSecretHash;

    event TokenListedSuccess (
        uint256 indexed tokenId,
        address owner,
        address seller,
        uint256 price,
        bool currentlyListed
    );

    event TokenUnlisted (
        uint256 indexed tokenId,
        address owner,
        address seller
    );

    event EncryptedTokenMinted(
        uint256 indexed tokenId,
        address indexed minter,
        bytes32 secretHash,
        uint256 price
    );

    event TokenUnlocked(
        uint256 indexed tokenId,
        address indexed claimer
    );

    constructor() ERC721("Impossible Dimension Market", "IDM") {
        owner = payable(msg.sender);
    }

   

    function createToken(string memory tokenURI_, uint256 price) external nonReentrant returns (uint256) {
        // price may be zero
        _tokenIds++;
        uint256 newTokenId = _tokenIds;

        _safeMint(msg.sender, newTokenId);
        _setTokenURI(newTokenId, tokenURI_);

        _createListedToken(newTokenId, price, msg.sender);

        return newTokenId;
    }

    /// @dev encryptedURI passed as bytes calldata. secretHash = keccak256(secret) (computed off-chain).
    function mintEncryptedToken(bytes calldata encryptedURI, bytes32 secretHash, uint256 price) external nonReentrant returns (uint256) {
        // price may be zero
        require(secretHash != bytes32(0), "MINT_ERROR: Secret hash cannot be zero");
        require(encryptedURI.length > 0, "MINT_ERROR: Encrypted URI cannot be empty");

        _tokenIds++;
        uint256 newTokenId = _tokenIds;

        // Mint to minter
        _safeMint(msg.sender, newTokenId);
        // Store encrypted bytes 
        encryptedTokenURI[newTokenId] = encryptedURI;
        // Store secret hash for one-time unlock
        tokenSecretHash[newTokenId] = secretHash;

        // Transfer token to marketplace and create listing
        _createListedToken(newTokenId, price, msg.sender);

        emit EncryptedTokenMinted(newTokenId, msg.sender, secretHash, price);
        return newTokenId;
    }

    /// @dev Internal helper used by createToken, mintEncryptedToken, listToken/resellToken
    function _createListedToken(uint256 tokenId, uint256 price, address lister) internal {
        // transfer token from lister to this contract (lister must be owner or approved)
        _transfer(lister, address(this), tokenId);

        idToListedToken[tokenId] = ListedToken(
            tokenId,
            payable(address(this)),
            payable(lister),
            price,
            true
        );

        emit TokenListedSuccess(tokenId, address(this), lister, price, true);
    }

   

    /// @notice List an existing token (owner can list). price may be zero.
    function listToken(uint256 tokenId, uint256 price) external nonReentrant {
        require(_tokenExists(tokenId), "LIST_ERROR: Token does not exist");
        require(ownerOf(tokenId) == msg.sender, "LIST_ERROR: Only token owner can list");
        // price may be zero

        _createListedToken(tokenId, price, msg.sender);
    }

    /// @notice Resell token after purchasing (owner can call to relist). price may be zero.
    function resellToken(uint256 tokenId, uint256 price) external nonReentrant {
        require(_tokenExists(tokenId), "RESELL_ERROR: Token does not exist");
        require(ownerOf(tokenId) == msg.sender, "RESELL_ERROR: Only token owner can resell");
        // price may be zero

        _createListedToken(tokenId, price, msg.sender);
    }

    /// @notice Cancel a listing and return token to seller 
    function cancelListing(uint256 tokenId) external nonReentrant {
        require(_tokenExists(tokenId), "CANCEL_ERROR: Token does not exist");
        ListedToken storage listed = idToListedToken[tokenId];
        require(listed.currentlyListed == true, "CANCEL_ERROR: Token is not currently listed");
        require(listed.seller == msg.sender, "CANCEL_ERROR: Only the seller can cancel this listing");
        require(ownerOf(tokenId) == address(this), "CANCEL_ERROR: Contract does not hold the token");

        address payable seller = listed.seller;

        listed.currentlyListed = false;
        listed.owner = seller;
        listed.seller = payable(address(0));

        _transfer(address(this), seller, tokenId);

        emit TokenUnlisted(tokenId, seller, address(0));
    }


    /// @notice Provide `secret` (bytes) used to XOR-decrypt stored encryptedURI. Contract will
    ///         verify keccak256(secret) matches stored hash, decrypt stored encryptedURI bytes,
    ///         set tokenURI to decrypted string, clear stored secret/encrypted bytes, and transfer token to caller.
    function unlockAndClaim(uint256 tokenId, bytes calldata secret) external nonReentrant {
        // Check 1: Token must exist
        require(_tokenExists(tokenId), "UNLOCK_ERROR: Token does not exist");

        ListedToken storage listed = idToListedToken[tokenId];
        
        // Check 2: Token must be currently listed
        require(listed.currentlyListed == true, "UNLOCK_ERROR: Token is not currently listed for unlock");
        
        // Check 3: Contract must hold the token
        address currentOwner = ownerOf(tokenId);
        require(currentOwner == address(this), "UNLOCK_ERROR: Marketplace does not hold the token");
        
        // Check 4: Secret must not be empty
        require(secret.length > 0, "UNLOCK_ERROR: Secret cannot be empty");

        // Check 5: Token must have a secret hash stored (meaning it was minted as encrypted)
        bytes32 storedHash = tokenSecretHash[tokenId];
        require(storedHash != bytes32(0), "UNLOCK_ERROR: Token is not encrypted or already unlocked");

        // Check 6: Verify the provided secret matches the stored hash
        bytes32 providedHash = keccak256(secret);
        require(providedHash == storedHash, "UNLOCK_ERROR: Invalid secret - hash mismatch");

        // Check 7: Encrypted data must exist
        bytes storage enc = encryptedTokenURI[tokenId];
        require(enc.length > 0, "UNLOCK_ERROR: No encrypted URI data stored for this token");

        // Decrypt (XOR) stored encrypted bytes with secret bytes
        bytes memory dec = _xorBytes(enc, secret);

        // Set the tokenURI to decrypted string
        string memory plainURI = string(dec);
        _setTokenURI(tokenId, plainURI);

        // Clear stored encrypted bytes & secretHash 
        delete encryptedTokenURI[tokenId];
        tokenSecretHash[tokenId] = bytes32(0);

        // Update listing state and transfer token to caller
        listed.currentlyListed = false;
        listed.owner = payable(msg.sender);
        listed.seller = payable(address(0));
        _itemsSold++;

        _transfer(address(this), msg.sender, tokenId);

        emit TokenUnlocked(tokenId, msg.sender);
    }

    function _xorBytes(bytes storage enc, bytes calldata secret) internal view returns (bytes memory) {
        uint256 n = enc.length;
        bytes memory out = new bytes(n);
        uint256 sLen = secret.length;
        require(sLen > 0, "secret length zero");

        for (uint256 i = 0; i < n; i++) {
            out[i] = bytes1(uint8(enc[i]) ^ uint8(secret[i % sLen]));
        }
        return out;
    }


    function executeSale(uint256 tokenId) external payable nonReentrant {
        require(_tokenExists(tokenId), "SALE_ERROR: Token does not exist");
        ListedToken storage listed = idToListedToken[tokenId];
        require(listed.currentlyListed == true, "SALE_ERROR: Token is not listed for sale");
        uint256 price = listed.price;
        address payable seller = listed.seller;
        require(msg.value == price, "SALE_ERROR: Incorrect payment amount - must match listing price exactly");

        // Effects
        listed.currentlyListed = false;
        listed.owner = payable(msg.sender);
        listed.seller = payable(address(0));
        _itemsSold++;

        // Transfer token
        _transfer(address(this), msg.sender, tokenId);

        if (price > 0) {
            (bool sentSeller, ) = seller.call{value: msg.value}("");
            require(sentSeller, "SALE_ERROR: Failed to send funds to seller");
        }

        emit TokenListedSuccess(tokenId, msg.sender, address(0), price, false);
    }


    /// @notice Return mapping info for a specific token id
    function getListedTokenForId(uint256 tokenId) external view returns (ListedToken memory) {
        return idToListedToken[tokenId];
    }

    /// @notice Get the stored secret hash for a token 
    function getTokenSecretHash(uint256 tokenId) external view returns (bytes32) {
        return tokenSecretHash[tokenId];
    }

    /// @notice Get the stored encrypted URI for a token (for debugging)
    function getEncryptedTokenURI(uint256 tokenId) external view returns (bytes memory) {
        return encryptedTokenURI[tokenId];
    }

    /// @notice Return latest listed token info (if any)
    function getLatestIdToListedToken() external view returns (ListedToken memory) {
        uint256 currentTokenId = _tokenIds;
        return idToListedToken[currentTokenId];
    }

    function getCurrentToken() external view returns (uint256) {
        return _tokenIds;
    }

    /// @notice Return all tokens (listed or not) represented as ListedToken entries.
    function getAllNFTs() external view returns (ListedToken[] memory) {
        uint total = _tokenIds;
        ListedToken[] memory tokens = new ListedToken[](total);
        for (uint i = 0; i < total; i++) {
            uint id = i + 1;
            tokens[i] = idToListedToken[id];
        }
        return tokens;
    }

    /// @notice Returns ListedToken[] for tokens where mapping indicates seller==user OR owner==user and currentlyListed==true
    function getListedTokensByUser(address user) external view returns (ListedToken[] memory) {
        uint total = _tokenIds;
        uint count = 0;

        for (uint i = 0; i < total; i++) {
            uint id = i + 1;
            ListedToken storage lt = idToListedToken[id];
            if (lt.seller == user || (lt.owner == user && lt.currentlyListed == true)) {
                count++;
            }
        }

        ListedToken[] memory results = new ListedToken[](count);
        uint idx = 0;
        for (uint i = 0; i < total; i++) {
            uint id = i + 1;
            ListedToken storage lt = idToListedToken[id];
            if (lt.seller == user || (lt.owner == user && lt.currentlyListed == true)) {
                results[idx] = lt;
                idx++;
            }
        }
        return results;
    }

    /// @notice Returns token IDs owned by the given user along with tokenURI
    function getTokensOwnedBy(address user) external view returns (TokenInfo[] memory) {
        uint total = _tokenIds;
        uint count = 0;
        for (uint i = 0; i < total; i++) {
            uint id = i + 1;
            if (_tokenExists(id)) {
                if (ownerOf(id) == user) {
                    count++;
                }
            }
        }

        TokenInfo[] memory results = new TokenInfo[](count);
        uint idx = 0;
        for (uint i = 0; i < total; i++) {
            uint id = i + 1;
            if (_tokenExists(id)) {
                if (ownerOf(id) == user) {
                    string memory uri = tokenURI(id);
                    results[idx] = TokenInfo(id, uri);
                    idx++;
                }
            }
        }
        return results;
    }

    /// @notice Convenience: returns tokens either owned by or previously listed by msg.sender
    function getMyNFTs() external view returns (ListedToken[] memory) {
        return this.getListedTokensByUser(msg.sender);
    }


    function _tokenExists(uint256 tokenId) internal view returns (bool) {
        try this.ownerOf(tokenId) returns (address) {
            return true;
        } catch {
            return false;
        }
    }


    receive() external payable {}
    fallback() external payable {}
}
