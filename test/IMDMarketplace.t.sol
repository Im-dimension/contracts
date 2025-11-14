// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {NFTMarketplace} from "../src/IMDMarketplace.sol";

contract IMDMarketplaceTest is Test {
    NFTMarketplace public marketplace;
    address public user1;
    address public user2;

    function setUp() public {
        marketplace = new NFTMarketplace();
        user1 = address(0x1);
        user2 = address(0x2);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }

    function test_CreateToken() public {
        vm.startPrank(user1);
        uint256 tokenId = marketplace.createToken("ipfs://test-uri", 1 ether);
        assertEq(tokenId, 1);
        vm.stopPrank();
    }

    function test_ExecuteSale() public {
        // User1 creates and lists token
        vm.startPrank(user1);
        uint256 tokenId = marketplace.createToken("ipfs://test-uri", 1 ether);
        vm.stopPrank();

        // User2 buys the token
        vm.startPrank(user2);
        marketplace.executeSale{value: 1 ether}(tokenId);
        assertEq(marketplace.ownerOf(tokenId), user2);
        vm.stopPrank();
    }
}
