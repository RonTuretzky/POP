// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BountyManagerPure} from "../src/BountyManagerPure.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBountyManagerPure {
    event BountyCreated(
        uint256 indexed id,
        address indexed token,
        uint256 payout,
        string description,
        address indexed creator,
        uint256 expiry
    );
    event BountyUpdated(uint256 indexed id, uint256 payout, string description);
    event BountyCompleted(uint256 indexed id, address indexed recipient, address indexed completer);
    event BountyCancelled(uint256 indexed id, address indexed canceller);
}

contract BountyManagerPureTest is Test {
    BountyManagerPure public bountyManager;
    ERC20Mock public token;
    address public creator;
    address public recipient;
    uint256 public constant INITIAL_BALANCE = 10000000 ether;
    uint256 public constant BOUNTY_AMOUNT = 1000 ether;

    function setUp() public {
        // Deploy contracts
        bountyManager = new BountyManagerPure();
        bountyManager.initialize();

        // Create test accounts
        creator = makeAddr("creator");
        recipient = makeAddr("recipient");

        // Deploy mock token and mint to creator
        token = new ERC20Mock();
        token.mint(creator, INITIAL_BALANCE);
    }

    function test_CreateBounty() public {
        vm.startPrank(creator);
        token.approve(address(bountyManager), BOUNTY_AMOUNT);

        uint256 expiry = block.timestamp + 7 days;
        vm.expectEmit(true, true, true, true);
        emit IBountyManagerPure.BountyCreated(0, address(token), BOUNTY_AMOUNT, "Test Bounty", creator, expiry);
        
        bountyManager.createBounty(token, BOUNTY_AMOUNT, "Test Bounty", expiry);
        vm.stopPrank();

        // Verify bounty state
        (
            uint256 payout,
            BountyManagerPure.Status status,
            ,  // creator
            ,  // token
            string memory description,
            uint256 bountyExpiry
        ) = bountyManager.getBounty(0);

        assertEq(payout, BOUNTY_AMOUNT);
        assertEq(uint256(status), uint256(BountyManagerPure.Status.ACTIVE));
        assertEq(description, "Test Bounty");
        assertEq(bountyExpiry, expiry);
        assertEq(bountyManager.activeBountyCount(), 1);
    }

    function test_CreateBountyWithInvalidExpiry() public {
        vm.startPrank(creator);
        token.approve(address(bountyManager), BOUNTY_AMOUNT);

        // Test expiry too soon
        vm.expectRevert(BountyManagerPure.InvalidExpiry.selector);
        bountyManager.createBounty(token, BOUNTY_AMOUNT, "Test Bounty", block.timestamp + 12 hours);

        // Test expiry too far
        vm.expectRevert(BountyManagerPure.InvalidExpiry.selector);
        bountyManager.createBounty(token, BOUNTY_AMOUNT, "Test Bounty", block.timestamp + 31 days);

        vm.stopPrank();
    }

    function test_UpdateBounty() public {
        // Create initial bounty
        vm.startPrank(creator);
        token.approve(address(bountyManager), BOUNTY_AMOUNT);
        uint256 expiry = block.timestamp + 7 days;
        bountyManager.createBounty(token, BOUNTY_AMOUNT, "Test Bounty", expiry);

        // Update bounty
        uint256 newPayout = BOUNTY_AMOUNT * 2;
        token.approve(address(bountyManager), newPayout);
        vm.expectEmit(true, true, true, true);
        emit IBountyManagerPure.BountyUpdated(0, newPayout, "Updated Bounty");
        bountyManager.updateBounty(0, newPayout, "Updated Bounty");
        vm.stopPrank();

        // Verify updated state
        (
            uint256 payout,
            BountyManagerPure.Status status,
            ,  // creator
            ,  // token
            string memory description,
            // expiry
        ) = bountyManager.getBounty(0);

        assertEq(payout, newPayout);
        assertEq(description, "Updated Bounty");
        assertEq(uint256(status), uint256(BountyManagerPure.Status.ACTIVE));
    }

    function test_CompleteBounty() public {
        // Create initial bounty
        vm.startPrank(creator);
        token.approve(address(bountyManager), BOUNTY_AMOUNT);
        uint256 expiry = block.timestamp + 7 days;
        bountyManager.createBounty(token, BOUNTY_AMOUNT, "Test Bounty", expiry);

        // Complete bounty
        vm.expectEmit(true, true, true, true);
        emit IBountyManagerPure.BountyCompleted(0, recipient, creator);
        bountyManager.completeBounty(0, recipient);
        vm.stopPrank();

        // Verify completed state
        (
            ,  // payout
            BountyManagerPure.Status status,
            ,  // creator
            ,  // token
            ,  // description
            // expiry
        ) = bountyManager.getBounty(0);

        assertEq(uint256(status), uint256(BountyManagerPure.Status.COMPLETED));
        assertEq(bountyManager.activeBountyCount(), 0);
        assertEq(token.balanceOf(recipient), BOUNTY_AMOUNT);
    }

    function test_GetActiveBounties() public {
        // Create multiple bounties
        vm.startPrank(creator);
        
        // Approve total amount needed for all bounties
        uint256 totalAmount = BOUNTY_AMOUNT * 6; // 3 bounties with potential 2x increase
        token.approve(address(bountyManager), totalAmount);

        // Create first bounty
        uint256 expiry1 = block.timestamp + 7 days;
        bountyManager.createBounty(token, BOUNTY_AMOUNT, "Bounty 1", expiry1);

        // Create second bounty
        uint256 expiry2 = block.timestamp + 14 days;
        bountyManager.createBounty(token, BOUNTY_AMOUNT * 2, "Bounty 2", expiry2);

        // Create third bounty that will be expired
        uint256 expiry3 = block.timestamp + 1 days;
        bountyManager.createBounty(token, BOUNTY_AMOUNT * 3, "Bounty 3", expiry3);
        vm.stopPrank();

        // Fast forward time to expire one bounty
        vm.warp(block.timestamp + 2 days);

        // Get active bounties
        (
            uint256[] memory ids,
            uint256[] memory payouts,
            address[] memory creators,
            IERC20[] memory tokens,
            string[] memory descriptions,
            uint256[] memory expiries
        ) = bountyManager.getActiveBounties();

        // Should only return 2 active bounties (third one expired)
        assertEq(ids.length, 2);
        assertEq(payouts.length, 2);
        assertEq(creators.length, 2);
        assertEq(tokens.length, 2);
        assertEq(descriptions.length, 2);
        assertEq(expiries.length, 2);

        // Verify first bounty data
        assertEq(ids[0], 0);
        assertEq(payouts[0], BOUNTY_AMOUNT);
        assertEq(creators[0], creator);
        assertEq(address(tokens[0]), address(token));
        assertEq(descriptions[0], "Bounty 1");
        assertEq(expiries[0], expiry1);

        // Verify second bounty data
        assertEq(ids[1], 1);
        assertEq(payouts[1], BOUNTY_AMOUNT * 2);
        assertEq(creators[1], creator);
        assertEq(address(tokens[1]), address(token));
        assertEq(descriptions[1], "Bounty 2");
        assertEq(expiries[1], expiry2);
    }

    function test_RevertWhenExpired() public {
        // Create bounty
        vm.startPrank(creator);
        token.approve(address(bountyManager), BOUNTY_AMOUNT);
        uint256 expiry = block.timestamp + 1 days;
        bountyManager.createBounty(token, BOUNTY_AMOUNT, "Test Bounty", expiry);

        // Fast forward time
        vm.warp(block.timestamp + 2 days);

        // Try to update expired bounty
        vm.expectRevert(BountyManagerPure.BountyExpired.selector);
        bountyManager.updateBounty(0, BOUNTY_AMOUNT, "Updated Bounty");

        // Try to complete expired bounty
        vm.expectRevert(BountyManagerPure.BountyExpired.selector);
        bountyManager.completeBounty(0, recipient);

        vm.stopPrank();
    }

    function test_RevertWhenNotCreator() public {
        // Create bounty
        vm.startPrank(creator);
        token.approve(address(bountyManager), BOUNTY_AMOUNT);
        uint256 expiry = block.timestamp + 7 days;
        bountyManager.createBounty(token, BOUNTY_AMOUNT, "Test Bounty", expiry);
        vm.stopPrank();

        // Try to update as non-creator
        vm.startPrank(recipient);
        vm.expectRevert(BountyManagerPure.NotCreator.selector);
        bountyManager.updateBounty(0, BOUNTY_AMOUNT, "Updated Bounty");

        // Try to complete as non-creator
        vm.expectRevert(BountyManagerPure.NotCreator.selector);
        bountyManager.completeBounty(0, recipient);
        vm.stopPrank();
    }

    function test_RevertWhenInvalidRecipient() public {
        // Create bounty
        vm.startPrank(creator);
        token.approve(address(bountyManager), BOUNTY_AMOUNT);
        uint256 expiry = block.timestamp + 7 days;
        bountyManager.createBounty(token, BOUNTY_AMOUNT, "Test Bounty", expiry);

        // Try to complete with zero address
        vm.expectRevert(BountyManagerPure.InvalidRecipient.selector);
        bountyManager.completeBounty(0, address(0));

        // Try to complete with creator address
        vm.expectRevert(BountyManagerPure.InvalidRecipient.selector);
        bountyManager.completeBounty(0, creator);

        vm.stopPrank();
    }
} 