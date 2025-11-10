// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Crowdfunding Smart Contract
 * @notice A decentralized crowdfunding platform where creators can launch campaigns
 *         and backers can contribute ETH toward funding goals.
 */
contract Project {
    address public admin;
    uint256 public campaignCount;

    struct Campaign {
        uint256 id;
        address payable creator;
        string title;
        string description;
        uint256 goal;
        uint256 deadline;
        uint256 raisedAmount;
        bool completed;
    }

    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => mapping(address => uint256)) public contributions;

    event CampaignCreated(uint256 indexed id, address indexed creator, string title, uint256 goal, uint256 deadline);
    event Funded(uint256 indexed id, address indexed backer, uint256 amount);
    event GoalReached(uint256 indexed id, uint256 totalRaised);
    event FundsWithdrawn(uint256 indexed id, address indexed creator, uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin allowed");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /**
     * @notice Create a new crowdfunding campaign
     * @param _title Campaign title
     * @param _description Campaign description
     * @param _goal Funding goal (in wei)
     * @param _duration Duration in seconds from now
     */
    function createCampaign(
        string memory _title,
        string memory _description,
        uint256 _goal,
        uint256 _duration
    ) external {
        require(_goal > 0, "Goal must be greater than 0");
        require(_duration > 0, "Duration must be valid");

        campaignCount++;
        campaigns[campaignCount] = Campaign({
            id: campaignCount,
            creator: payable(msg.sender),
            title: _title,
            description: _description,
            goal: _goal,
            deadline: block.timestamp + _duration,
            raisedAmount: 0,
            completed: false
        });

        emit CampaignCreated(campaignCount, msg.sender, _title, _goal, block.timestamp + _duration);
    }

    /**
     * @notice Contribute ETH to a campaign
     * @param _id Campaign ID
     */
    function fundCampaign(uint256 _id) external payable {
        Campaign storage campaign = campaigns[_id];
        require(block.timestamp < campaign.deadline, "Campaign expired");
        require(!campaign.completed, "Campaign completed");
        require(msg.value > 0, "Send some ETH");

        campaign.raisedAmount += msg.value;
        contributions[_id][msg.sender] += msg.value;

        emit Funded(_id, msg.sender, msg.value);

        if (campaign.raisedAmount >= campaign.goal) {
            campaign.completed = true;
            emit GoalReached(_id, campaign.raisedAmount);
        }
    }

    /**
     * @notice Withdraw raised funds (only by creator if goal met)
     * @param _id Campaign ID
     */
    function withdrawFunds(uint256 _id) external {
        Campaign storage campaign = campaigns[_id];
        require(msg.sender == campaign.creator, "Only creator can withdraw");
        require(campaign.completed, "Goal not yet reached");
        require(campaign.raisedAmount > 0, "No funds available");

        uint256 amount = campaign.raisedAmount;
        campaign.raisedAmount = 0;
        campaign.creator.transfer(amount);

        emit FundsWithdrawn(_id, msg.sender, amount);
    }

    /**
     * @notice Get details of a campaign
     * @param _id Campaign ID
     */
    function getCampaign(uint256 _id) external view returns (Campaign memory) {
        return campaigns[_id];
    }
}
    




