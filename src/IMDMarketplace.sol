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

    /// @dev Compatibility helper to determine whether a token exists without relying on internal `_exists()`.
    /// Uses try/catch around external call to `ownerOf` which reverts for non-existent tokens.
    function _tokenExists(uint256 tokenId) internal view returns (bool) {
        try this.ownerOf(tokenId) returns (address) {
            return true;
        } catch {
            return false;
        }
    }
}
