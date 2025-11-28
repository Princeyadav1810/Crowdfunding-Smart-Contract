// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Crowdfunding
/// @notice Simple, secure crowdfunding platform with refundable contributions
/// @dev No external imports so it's easy to drop into Remix / Hardhat
contract Crowdfunding {
    address public admin;
    uint256 public campaignCount;

    enum CampaignState { Active, Cancelled, Successful, Failed, Withdrawn }

    struct Campaign {
        uint256 id;
        address payable creator;
        string title;
        string descriptionURI; // optional URI (IPFS, etc.)
        uint256 goal;          // funding goal in wei
        uint256 pledged;       // amount pledged so far in wei
        uint256 deadline;      // unix timestamp deadline
        bool withdrawn;        // whether creator has withdrawn funds
        CampaignState state;
    }

    // campaignId => Campaign
    mapping(uint256 => Campaign) public campaigns;
    // campaignId => contributor => amount
    mapping(uint256 => mapping(address => uint256)) public contributions;

    event CampaignCreated(
        uint256 indexed id,
        address indexed creator,
        uint256 goal,
        uint256 deadline,
        string title,
        string descriptionURI
    );
    event ContributionReceived(
        uint256 indexed campaignId,
        address indexed contributor,
        uint256 amount
    );
    event CampaignCancelled(uint256 indexed campaignId);
    event FundsWithdrawn(uint256 indexed campaignId, uint256 amount);
    event RefundClaimed(uint256 indexed campaignId, address indexed contributor, uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Crowdfunding: NOT_ADMIN");
        _;
    }

    modifier campaignExists(uint256 id) {
        require(id > 0 && id <= campaignCount, "Crowdfunding: CAMPAIGN_NOT_FOUND");
        _;
    }

    // simple reentrancy guard
    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "Crowdfunding: REENTRANT");
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor() {
        admin = msg.sender;
    }

    /// @notice Create a new crowdfunding campaign
    /// @param title Short title for the campaign
    /// @param descriptionURI Optional URI for more details (IPFS, http, etc.)
    /// @param goal Funding goal in wei (must be > 0)
    /// @param durationSeconds How long the campaign runs from now (seconds, must be > 0)
    function createCampaign(
        string calldata title,
        string calldata descriptionURI,
        uint256 goal,
        uint256 durationSeconds
    ) external returns (uint256) {
        require(goal > 0, "Crowdfunding: INVALID_GOAL");
        require(durationSeconds > 0, "Crowdfunding: INVALID_DURATION");

        campaignCount++;
        uint256 id = campaignCount;

        campaigns[id] = Campaign({
            id: id,
            creator: payable(msg.sender),
            title: title,
            descriptionURI: descriptionURI,
            goal: goal,
            pledged: 0,
            deadline: block.timestamp + durationSeconds,
            withdrawn: false,
            state: CampaignState.Active
        });

        emit CampaignCreated(id, msg.sender, goal, campaigns[id].deadline, title, descriptionURI);
        return id;
    }

    /// @notice Contribute to an active campaign
    /// @dev Payable function; sends ether to be held until withdrawal or refund
    /// @param campaignId The campaign to contribute to
    function contribute(uint256 campaignId) external payable campaignExists(campaignId) nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(c.state == CampaignState.Active, "Crowdfunding: NOT_ACTIVE");
        require(block.timestamp <= c.deadline, "Crowdfunding: PAST_DEADLINE");
        require(msg.value > 0, "Crowdfunding: ZERO_CONTRIBUTION");

        c.pledged += msg.value;
        contributions[campaignId][msg.sender] += msg.value;

        emit ContributionReceived(campaignId, msg.sender, msg.value);

        // If goal reached before deadline, mark it as Successful immediately
        if (c.pledged >= c.goal) {
            c.state = CampaignState.Successful;
        }
    }

    /// @notice Cancel a campaign (only creator) while it's still active and before deadline
    /// @dev After cancellation contributors can claim refunds
    /// @param campaignId ID of the campaign
    function cancelCampaign(uint256 campaignId) external campaignExists(campaignId) nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(msg.sender == c.creator || msg.sender == admin, "Crowdfunding: UNAUTHORIZED");
        require(c.state == CampaignState.Active, "Crowdfunding: NOT_ACTIVE");

        c.state = CampaignState.Cancelled;
        emit CampaignCancelled(campaignId);
    }

    /// @notice Withdraw funds by campaign creator if goal met
    /// @dev Transfers total pledged to creator and marks as withdrawn
    /// @param campaignId ID of the campaign
    function withdrawFunds(uint256 campaignId) external campaignExists(campaignId) nonReentrant {
        Campaign storage c = campaigns[campaignId];
        require(msg.sender == c.creator, "Crowdfunding: ONLY_CREATOR");
        require(c.state == CampaignState.Successful || (block.timestamp > c.deadline && c.pledged >= c.goal),
                "Crowdfunding: GOAL_NOT_MET");
        require(!c.withdrawn, "Crowdfunding: ALREADY_WITHDRAWN");

        uint256 amount = c.pledged;
        c.withdrawn = true;
        c.state = CampaignState.Withdrawn;

        // zero out pledged before transfer to be extra-safe (though we set withdrawn)
        c.pledged = 0;

        (bool ok, ) = c.creator.call{value: amount}("");
        require(ok, "Crowdfunding: TRANSFER_FAILED");

        emit FundsWithdrawn(campaignId, amount);
    }

    /// @notice Claim refund for a contributor if campaign failed, deadline passed or campaign cancelled
    /// @param campaignId ID of the campaign
    function claimRefund(uint256 campaignId) external campaignExists(campaignId) nonReentrant {
        Campaign storage c = campaigns[campaignId];

        bool failed = (block.timestamp > c.deadline && c.pledged < c.goal);
        bool cancelled = (c.state == CampaignState.Cancelled);

        require(failed || cancelled, "Crowdfunding: NOT_REFUNDABLE");

        uint256 contributed = contributions[campaignId][msg.sender];
        require(contributed > 0, "Crowdfunding: NO_CONTRIBUTION");

        // zero out contributor balance before transfer
        contributions[campaignId][msg.sender] = 0;

        // deduct from pledged so bookkeeping stays accurate
        if (c.pledged >= contributed) {
            c.pledged -= contributed;
        } else {
            c.pledged = 0;
        }

        (bool ok, ) = payable(msg.sender).call{value: contributed}("");
        require(ok, "Crowdfunding: REFUND_FAILED");

        emit RefundClaimed(campaignId, msg.sender, contributed);
    }

    /// @notice Admin helper to mark campaigns that passed deadline as failed (optional)
    /// @dev This is a gas-optional helper for frontends to change state for readability
    /// @param campaignId ID of the campaign
    function finalizeCampaign(uint256 campaignId) external campaignExists(campaignId) {
        Campaign storage c = campaigns[campaignId];
        require(c.state == CampaignState.Active || c.state == CampaignState.Successful, "Crowdfunding: NOT_FINALIZABLE");

        if (block.timestamp > c.deadline) {
            if (c.pledged >= c.goal) {
                c.state = CampaignState.Successful;
            } else {
                c.state = CampaignState.Failed;
            }
        } else {
            revert("Crowdfunding: DEADLINE_NOT_REACHED");
        }
    }

    /// @notice View function to get campaign details
    function getCampaign(uint256 id) external view campaignExists(id) returns (
        uint256 campaignId,
        address creator,
        string memory title,
        string memory descriptionURI,
        uint256 goal,
        uint256 pledged,
        uint256 deadline,
        bool withdrawn,
        CampaignState state
    ) {
        Campaign storage c = campaigns[id];
        return (
            c.id,
            c.creator,
            c.title,
            c.descriptionURI,
            c.goal,
            c.pledged,
            c.deadline,
            c.withdrawn,
            c.state
        );
    }

    /// @notice Get how much an address contributed to a campaign
    function getContribution(uint256 campaignId, address contributor) external view returns (uint256) {
        return contributions[campaignId][contributor];
    }

    /// @notice Change admin (admin only)
    function changeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Crowdfunding: ZERO_ADDRESS");
        admin = newAdmin;
    }

    /// @notice Accept plain ETH sent to contract as contribution to a default campaign (not used here)
    receive() external payable {
        revert("Crowdfunding: USE_contribute_FUNCTION");
    }

    fallback() external payable {
        revert("Crowdfunding: INVALID_CALL");
    }
}
