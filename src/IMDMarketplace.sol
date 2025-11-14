// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title NFT Marketplace (mint, list, buy, resell, cancel, queries)

contract NFTMarketplace is ERC721URIStorage, ReentrancyGuard {
    uint256 private _tokenIds;
    uint256 private _itemsSold;

    address payable public owner;

    struct ListedToken {
        uint256 tokenId;
        address payable owner;   
        address payable seller;  
        uint256 price;
        bool currentlyListed;
    }

    // Struct to return tokenId + tokenURI together
    struct TokenInfo {
        uint256 tokenId;
        string tokenURI;
    }

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

    mapping(uint256 => ListedToken) private idToListedToken;

    constructor() ERC721("Impossible Dimension Market", "IDM") {
    owner = payable(msg.sender);
    }




    /// @notice Mint a new token and list it for sale 
    function createToken(string memory tokenURI_, uint256 price) external nonReentrant returns (uint256) {
        require(price >= 0, "Price must be positive");

        _tokenIds++;
        uint256 newTokenId = _tokenIds;

        // Mint token to the minter
        _safeMint(msg.sender, newTokenId);
        _setTokenURI(newTokenId, tokenURI_);

        // Create the listing by transferring token to contract
        _createListedToken(newTokenId, price, msg.sender);

        return newTokenId;
    }

    /// @dev Internal helper used by createToken and listToken/resellToken
    function _createListedToken(uint256 tokenId, uint256 price, address lister) internal {
        // Transfer token from lister to this contract (lister must be owner)
        _transfer(lister, address(this), tokenId);

        idToListedToken[tokenId] = ListedToken(
            tokenId,
            payable(address(this)),        // contract holds it while listed
            payable(lister),
            price,
            true
        );

        emit TokenListedSuccess(tokenId, address(this), lister, price, true);
    }

   

    function listToken(uint256 tokenId, uint256 price) external nonReentrant {
        require(_tokenExists(tokenId), "Token doesn't exist");
        require(ownerOf(tokenId) == msg.sender, "Only token owner can list");
        require(price > 0, "Price must be positive");

        // Transfer token to marketplace contract and create mapping entry
        _createListedToken(tokenId, price, msg.sender);
    }

    /// @notice Resell token after purchasing (owner can call to relist)
    function resellToken(uint256 tokenId, uint256 price) external nonReentrant {
        require(_tokenExists(tokenId), "Token doesn't exist");
        require(ownerOf(tokenId) == msg.sender, "Only token owner can resell");
        require(price > 0, "Price must be positive");

        _createListedToken(tokenId, price, msg.sender);
    }

    /* ========== CANCEL LISTING ========== */

    /// @notice Allows the seller (who listed it) to cancel their listing 
    function cancelListing(uint256 tokenId) external nonReentrant {
        require(_tokenExists(tokenId), "Token doesn't exist");
        ListedToken storage listed = idToListedToken[tokenId];
        require(listed.currentlyListed == true, "Token is not listed");
        require(listed.seller == msg.sender, "Only seller can cancel listing");
        require(ownerOf(tokenId) == address(this), "Contract does not hold the token");

        address payable seller = listed.seller;

        // Update mapping: mark unlisted and set owner to seller
        listed.currentlyListed = false;
        listed.owner = seller;               // seller regains ownership in mapping
        listed.seller = payable(address(0)); // clear seller

        // Transfer token back to seller
        _transfer(address(this), seller, tokenId);

        emit TokenUnlisted(tokenId, seller, address(0));
    }

    

    /// @notice Buy a listed token by sending the exact price (msg.value)
    function executeSale(uint256 tokenId) external payable nonReentrant {
        require(_tokenExists(tokenId), "Token doesn't exist");
        ListedToken storage listed = idToListedToken[tokenId];
        require(listed.currentlyListed == true, "Token is not listed for sale");
        uint256 price = listed.price;
        address payable seller = listed.seller;
        require(msg.value == price, "Please submit the asking price to complete the purchase");

        // Effects: update storage before making external calls
        listed.currentlyListed = false;
        listed.owner = payable(msg.sender);   // buyer becomes holder in mapping
        listed.seller = payable(address(0));  // clear seller
        _itemsSold++;

        // Transfer token to buyer
        _transfer(address(this), msg.sender, tokenId);

       
        (bool sentSeller, ) = seller.call{value: msg.value}("");
        require(sentSeller, "Failed to send funds to seller");

        emit TokenListedSuccess(tokenId, msg.sender, address(0), price, false);
    }



    /// @notice Return mapping info for a specific token id
    function getListedTokenForId(uint256 tokenId) external view returns (ListedToken memory) {
        return idToListedToken[tokenId];
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
                // ownerOf(id) will not revert because _tokenExists returned true
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

    /// @dev Compatibility helper to determine whether a token exists without relying on internal `_exists()`.
    /// Uses try/catch around external call to `ownerOf` which reverts for non-existent tokens.
    function _tokenExists(uint256 tokenId) internal view returns (bool) {
        try this.ownerOf(tokenId) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    /* ========== FALLBACKS ========== */

    // No withdraw needed since listing fees were removed, but accept ETH if someone sends.
    receive() external payable {}
    fallback() external payable {}
}
