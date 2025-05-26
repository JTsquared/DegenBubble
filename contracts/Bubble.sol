// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DegenBubble is Ownable {
    struct Bubble {
        IERC20[] acceptedTokens;
        address bubbleCreator;
        bool isActive;
        uint256 popProbability;
        uint256 burnPercentage;
        IERC20 initialDepositToken;
        uint256 depositCount;
        uint256 lastDepositTime;
    }

    Bubble[] public bubbles;
    uint256[] private reusableIndexes;
    uint256 public maxBubbles = 500;
    address public developerAddress;
    address public shameWallet;
    IERC721 public nftCollection;
    mapping(address => uint256) public userBubbleCount;
    mapping(bytes32 => bool) public existingBubbles;
    uint256 public requiredNFTCount = 5;
    
    mapping(uint256 => mapping(address => bool)) public acceptedTokensMap; // (bubbleId => token => bool)
    mapping(uint256 => mapping(IERC20 => uint256)) public popPools; // (bubbleId => token => amount)
    mapping(uint256 => mapping(address => uint256)) public depositPrices; // (bubbleId => token => amount)

    event BubbleCreated(uint256 indexed bubbleId, address indexed creator, address[] acceptedTokens);
    event Deposited(uint256 indexed bubbleId, address indexed user, uint256 amount, address token);
    event Popped(uint256 indexed bubbleId, address indexed user, address[] tokens, uint256[] amounts);
    event CreatorRewardsSent(uint256 indexed bubbleId, address indexed rewardRecipient, address[] tokens, uint256[] amounts
);
    event ManualPop(uint256 indexed bubbleId, address indexed triggeredBy, uint256 refundAmount);
    event AdminDeposited(uint256 indexed bubbleId, address indexed user, uint256 amount, address token);


    constructor() Ownable(msg.sender) {
        developerAddress = msg.sender;
        shameWallet = 0x548d1E25C33C7f2255471B350fFf96Bd23a775eb;
        nftCollection = IERC721(0x5dbC5A50df2B7b61b5C67FecFe552D8984424315);
    }

    function createBubble(
        uint256 _popProbability,
        uint256 _burnPercentage,
        IERC20[] memory _tokens,
        uint256[] memory _depositPrices
    ) external {
        require(_tokens.length == _depositPrices.length, "Mismatched inputs");
        require(_tokens.length > 0 && _tokens.length <= 5, "Must accept 1-5 tokens");
        require(_popProbability <= 2500, "Probability out of range"); // ---> 1/25 min
        require(_burnPercentage <= 10000, "Burn percentage out of range");
        require(nftCollection.balanceOf(msg.sender) >= requiredNFTCount, "You do not own enough NFTs to create a Bubble");
        require(bubbles.length < maxBubbles || reusableIndexes.length > 0, "Bubble limit reached");
        bytes32 bubbleHash = getBubbleHash(_tokens, _popProbability);
        require(!existingBubbles[bubbleHash], "Similar bubble already exists");
        existingBubbles[bubbleHash] = true;
        require(userBubbleCount[msg.sender] < nftCollection.balanceOf(msg.sender) / requiredNFTCount, "Bubble creation limit reached");

        uint256 bubbleId;
        if (reusableIndexes.length > 0) {
            bubbleId = reusableIndexes[reusableIndexes.length - 1];
            reusableIndexes.pop();
        } else {
            bubbleId = bubbles.length;
            bubbles.push();
        }

        // Reset state for reused bubbleId
        Bubble storage reusedBubble = bubbles[bubbleId];
        for (uint256 i = 0; i < reusedBubble.acceptedTokens.length; i++) {
            bytes32 oldHash = getBubbleHash(reusedBubble.acceptedTokens, reusedBubble.popProbability);
            existingBubbles[oldHash] = false;
            address tokenAddress = address(reusedBubble.acceptedTokens[i]);
            acceptedTokensMap[bubbleId][tokenAddress] = false;
            popPools[bubbleId][reusedBubble.acceptedTokens[i]] = 0;
            depositPrices[bubbleId][tokenAddress] = 0;
        }

        delete reusedBubble.acceptedTokens;
        reusedBubble.depositCount = 0;
        reusedBubble.lastDepositTime = 0;

        Bubble storage newBubble = bubbles[bubbleId];
        newBubble.acceptedTokens = _tokens;
        newBubble.bubbleCreator = msg.sender;
        newBubble.isActive = true;
        newBubble.popProbability = _popProbability;
        newBubble.burnPercentage = _burnPercentage;
        newBubble.initialDepositToken = _tokens[0];
        newBubble.lastDepositTime = block.timestamp;

        address[] memory tokenAddresses = new address[](_tokens.length);

        for (uint256 i = 0; i < _tokens.length; i++) {
            require(_depositPrices[i] > 0, "Deposit price must be greater than 0");
            require(!acceptedTokensMap[bubbleId][address(_tokens[i])], "Duplicate token");
            acceptedTokensMap[bubbleId][address(_tokens[i])] = true;
            depositPrices[bubbleId][address(_tokens[i])] = _depositPrices[i];
            tokenAddresses[i] = address(_tokens[i]);
        }

        uint256 initialDeposit = (_popProbability * 2500 * _depositPrices[0]) / 10000;
        IERC20 depositToken = _tokens[0];
        require(depositToken.transferFrom(msg.sender, address(this), initialDeposit), "Initial deposit failed");
        popPools[bubbleId][depositToken] += initialDeposit;
        
        userBubbleCount[msg.sender]++;
        
        emit BubbleCreated(bubbleId, msg.sender, tokenAddresses);
    }

    function getBubbleHash(IERC20[] memory _tokens, uint256 _popProbability) internal pure returns (bytes32) {
        address[] memory tokenAddresses = new address[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            tokenAddresses[i] = address(_tokens[i]);
        }

        // Sort token addresses to ensure order doesn't matter
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            for (uint256 j = i + 1; j < tokenAddresses.length; j++) {
                if (tokenAddresses[i] > tokenAddresses[j]) {
                    (tokenAddresses[i], tokenAddresses[j]) = (tokenAddresses[j], tokenAddresses[i]);
                }
            }
        }
        return keccak256(abi.encodePacked(tokenAddresses, _popProbability));
    }

    function isAcceptedToken(uint256 bubbleId, IERC20 token) internal view returns (bool) {
        return acceptedTokensMap[bubbleId][address(token)];
    }

    function getTicketPrice(uint256 bubbleId, IERC20 token) internal view returns (uint256) {
        return depositPrices[bubbleId][address(token)];
    }

    function deposit(uint256 bubbleId, IERC20 token) external {
        Bubble storage bubble = bubbles[bubbleId];
        uint256 ticketPrice = getTicketPrice(bubbleId, token);
        require(bubble.isActive, "Bubble has popped!");
        require(isAcceptedToken(bubbleId, token), "Token not accepted");
        require(token.allowance(msg.sender, address(this)) >= ticketPrice, "Insufficient allowance");
        require(token.transferFrom(msg.sender, address(this), ticketPrice), "Deposit failed");

        uint256 devFee = (getTicketPrice(bubbleId, token) * 2) / 100;
        uint256 userContribution = ticketPrice - devFee;
        popPools[bubbleId][token] += userContribution;
        require(token.transfer(developerAddress, devFee), "Developer fee transfer failed");

        bubble.depositCount++;
        if (shouldPop(bubble)) {
            triggerPop(bubbleId, msg.sender);
        }

        bubble.lastDepositTime = block.timestamp;

        emit Deposited(bubbleId, msg.sender, ticketPrice, address(token));
    }

    function shouldPop(Bubble storage bubble) internal view returns (bool) {
        uint256 adjustedPopProbability = bubble.popProbability - (bubble.popProbability * bubble.depositCount / 1000000);
        if (adjustedPopProbability <= 2000000) {
            adjustedPopProbability = 2000000;
        }
        return (uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender))) % 10000000) < adjustedPopProbability;
    }

    function triggerPop(uint256 bubbleId, address user) internal {
        Bubble storage bubble = bubbles[bubbleId];
        require(bubble.isActive, "Bubble has already popped!");
        bubble.isActive = false;

        address[] memory poppedTokens = new address[](bubble.acceptedTokens.length);
        uint256[] memory poppedAmounts = new uint256[](bubble.acceptedTokens.length);

        address[] memory rewardTokens = new address[](bubble.acceptedTokens.length);
        uint256[] memory rewardAmounts = new uint256[](bubble.acceptedTokens.length);

        uint256 popIndex = 0;
        uint256 rewardIndex = 0;

        for (uint256 i = 0; i < bubble.acceptedTokens.length; i++) {
            (
                bool success,
                address tokenAddress,
                uint256 popAmount,
                uint256 rewardAmount
            ) = handleTokenPop(bubbleId, user, i);

            if (success) {
                poppedTokens[popIndex] = tokenAddress;
                poppedAmounts[popIndex] = popAmount;
                popIndex++;

                if (rewardAmount > 0) {
                    rewardTokens[rewardIndex] = tokenAddress;
                    rewardAmounts[rewardIndex] = rewardAmount;
                    rewardIndex++;
                }
            }
        }

        if (popIndex > 0) {
            address[] memory finalPoppedTokens = new address[](popIndex);
            uint256[] memory finalPoppedAmounts = new uint256[](popIndex);
            for (uint256 i = 0; i < popIndex; i++) {
                finalPoppedTokens[i] = poppedTokens[i];
                finalPoppedAmounts[i] = poppedAmounts[i];
            }
            emit Popped(bubbleId, user, finalPoppedTokens, finalPoppedAmounts);
        }

        if (rewardIndex > 0) {
            address[] memory finalRewardTokens = new address[](rewardIndex);
            uint256[] memory finalRewardAmounts = new uint256[](rewardIndex);
            for (uint256 i = 0; i < rewardIndex; i++) {
                finalRewardTokens[i] = rewardTokens[i];
                finalRewardAmounts[i] = rewardAmounts[i];
            }
            emit CreatorRewardsSent(bubbleId, bubble.bubbleCreator, finalRewardTokens, finalRewardAmounts);
        }

        reusableIndexes.push(bubbleId);
        userBubbleCount[bubble.bubbleCreator]--;
        clearBubbleMetadata(bubbleId);
    }

    function handleTokenPop(uint256 bubbleId, address user, uint256 index) internal returns (
        bool success,
        address tokenAddress,
        uint256 popAmount,
        uint256 creatorReward
    ) {
        Bubble storage bubble = bubbles[bubbleId];
        IERC20 token = bubble.acceptedTokens[index];
        tokenAddress = address(token);

        uint256 poolAmount = popPools[bubbleId][token];
        if (poolAmount == 0) return (false, tokenAddress, 0, 0);

        uint256 oneThird = bubble.popProbability / 3;
        uint256 popPercentage = bubble.depositCount < oneThird
            ? 70
            : bubble.depositCount < 2 * oneThird
                ? 60
                : 50;

        popAmount = (poolAmount * popPercentage) / 100;
        uint256 burnAmount = (poolAmount * bubble.burnPercentage) / 10000;
        creatorReward = poolAmount - popAmount - burnAmount;

        popPools[bubbleId][token] = 0;

        require(token.transfer(user, popAmount), "Pop payout failed");

        if (burnAmount > 0) {
            address deadWallet = 0x000000000000000000000000000000000000dEaD;
            require(token.transfer(deadWallet, burnAmount), "Burn failed");
        }

        if (creatorReward > 0) {
            uint256 creatorBubbleCount = userBubbleCount[bubble.bubbleCreator];
            uint256 requiredTotalNFTs = creatorBubbleCount * requiredNFTCount;
            uint256 creatorNFTBalance = nftCollection.balanceOf(bubble.bubbleCreator);

            if (creatorNFTBalance < requiredTotalNFTs) {
                require(token.transfer(shameWallet, creatorReward), "Shame wallet transfer failed");
            } else {
                require(token.transfer(bubble.bubbleCreator, creatorReward), "Creator reward failed");
            }
        }

        return (true, tokenAddress, popAmount, creatorReward);
    }


    function manualPop(uint256 bubbleId) external {
        Bubble storage bubble = bubbles[bubbleId];
        require(bubble.bubbleCreator != address(0), "Invalid bubble ID");
        require(block.timestamp >= bubble.lastDepositTime + 7 days, "Must wait 7 days since last deposit");
        require(bubble.isActive, "Bubble already popped");

        bubble.isActive = false;

        uint256 refundAmount = (bubble.popProbability * 2500 * getTicketPrice(bubbleId, bubble.initialDepositToken)) / 10000;
        IERC20 depositToken = bubble.initialDepositToken;
        require(popPools[bubbleId][depositToken] >= refundAmount, "Insufficient balance for refund");
        require(depositToken.transfer(bubble.bubbleCreator, refundAmount), "Refund failed");
        popPools[bubbleId][depositToken] -= refundAmount;


        for (uint256 i = 0; i < bubble.acceptedTokens.length; i++) {
            IERC20 token = bubble.acceptedTokens[i];
            uint256 remainingBalance = popPools[bubbleId][token];
            if (remainingBalance > 0) {
                require(token.transfer(shameWallet, remainingBalance), "Transfer to shameWallet failed");
                popPools[bubbleId][token] = 0;
            }
        }

        reusableIndexes.push(bubbleId);
        userBubbleCount[bubble.bubbleCreator]--;

        emit ManualPop(bubbleId, msg.sender, refundAmount);

        clearBubbleMetadata(bubbleId);
    }

    function clearBubbleMetadata(uint256 bubbleId) internal {
        Bubble storage b = bubbles[bubbleId];
        bytes32 hash = getBubbleHash(b.acceptedTokens, b.popProbability);
        existingBubbles[hash] = false;
        
        for (uint256 i = 0; i < b.acceptedTokens.length; i++) {
            address token = address(b.acceptedTokens[i]);
            acceptedTokensMap[bubbleId][token] = false;
            depositPrices[bubbleId][token] = 0;
        }
    }

    function getAcceptedTokens(uint256 bubbleId) external view returns (address[] memory) {
        Bubble storage b = bubbles[bubbleId];
        uint256 len = b.acceptedTokens.length;
        address[] memory tokens = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            tokens[i] = address(b.acceptedTokens[i]);
        }
        return tokens;
    }

    function getDepositPrices(uint256 bubbleId) external view returns (uint256[] memory) {
        Bubble storage b = bubbles[bubbleId];
        uint256 len = b.acceptedTokens.length;
        uint256[] memory prices = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            prices[i] = depositPrices[bubbleId][address(b.acceptedTokens[i])];
        }
        return prices;
    }

   function getPopPool(uint256 bubbleId) external view returns (uint256[] memory) {
        Bubble storage b = bubbles[bubbleId];
        uint256 len = b.acceptedTokens.length;
        uint256[] memory poolAmounts = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            poolAmounts[i] = popPools[bubbleId][b.acceptedTokens[i]]; // No casting needed
        }
        return poolAmounts;
    }

    function setShameWallet(address _newShameWallet) external onlyOwner {
        require(_newShameWallet != address(0), "Invalid address");
        shameWallet = _newShameWallet;
    }

    function setDeveloperWallet(address _newDeveloperWallet) external onlyOwner {
        require(_newDeveloperWallet != address(0), "Invalid address");
        developerAddress = _newDeveloperWallet;
    }

    function setRequireNFTCollection(address _newNftAddress) external onlyOwner {
        require(_newNftAddress != address(0), "Invalid address");
        nftCollection = IERC721(_newNftAddress);
    }

    function setRequiredNFTCount(uint256 _count) external onlyOwner {
        requiredNFTCount = _count;
    }

    function adminDeposit(uint256 bubbleId, IERC20 token, uint256 amount) external {
        Bubble storage bubble = bubbles[bubbleId];
        require(bubble.isActive, "Cannot deposit into an inactive bubble");
        require(isAcceptedToken(bubbleId, token), "Token not accepted");
        require(amount > 0, "Amount must be greater than 0");
        require(token.allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        popPools[bubbleId][token] += amount;

        emit AdminDeposited(bubbleId, msg.sender, amount, address(token));
    }

    //in case a token rugs prevents "free" ticket purchases
    function adminRemoveAcceptedToken(uint256 bubbleId, IERC20 token) external onlyOwner {
        acceptedTokensMap[bubbleId][address(token)] = false;
        delete depositPrices[bubbleId][address(token)];
    }

}
