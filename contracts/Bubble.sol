// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BubbleGame is Ownable {
    struct Bubble {
        IERC20[] acceptedTokens;
        address bubbleCreator;
        bool isActive;
        uint256 popProbability;
        uint256 burnPercentage;
        uint256 depositPrice;
        uint256 depositCount;
        mapping(IERC20 => uint256) popPool;
    }

    Bubble[] public bubbles;
    uint256[] private reusableIndexes;
    uint256 public maxBubbles = 500;
    address public developerAddress;
    address public shameWallet;
    IERC721 public nftCollection;
    mapping(address => uint256) public userBubbleCount;

    event Deposited(uint256 indexed bubbleId, address indexed user, uint256 amount, address token);
    event Popped(uint256 indexed bubbleId, address indexed user, uint256 amount, address token);

    constructor(address _nftCollection) Ownable(msg.sender) {
        developerAddress = msg.sender;
        shameWallet = 0x548d1E25C33C7f2255471B350fFf96Bd23a775eb;
        nftCollection = IERC721(_nftCollection);
    }

    function createBubble(
        uint256 _popProbability,
        uint256 _burnPercentage,
        IERC20[] memory _tokens,
        uint256 _depositPrice
    ) external {
        require(_tokens.length > 0 && _tokens.length <= 5, "Must accept 1-5 tokens");
        require(_popProbability <= 2500, "Probability out of range"); // ---> 1/25 min
        require(_burnPercentage <= 10000, "Burn percentage out of range");
        require(nftCollection.balanceOf(msg.sender) >= 5, "Must own an NFT to create a Bubble");
        require(bubbles.length < maxBubbles || reusableIndexes.length > 0, "Bubble limit reached");
        require(!isDuplicateBubble(_tokens, _popProbability), "Similar bubble already exists");
        require(userBubbleCount[msg.sender] < nftCollection.balanceOf(msg.sender) / 5, "Bubble creation limit reached");

        uint256 bubbleId;
        if (reusableIndexes.length > 0) {
            bubbleId = reusableIndexes[reusableIndexes.length - 1];
            reusableIndexes.pop();
        } else {
            bubbleId = bubbles.length;
            bubbles.push();
        }

        Bubble storage newBubble = bubbles[bubbleId];
        newBubble.acceptedTokens = _tokens;
        newBubble.bubbleCreator = msg.sender;
        newBubble.isActive = true;
        newBubble.popProbability = _popProbability;
        newBubble.burnPercentage = _burnPercentage;
        newBubble.depositPrice = _depositPrice;

        uint256 initialDeposit = (_popProbability * 2500 * _depositPrice) / 10000;
        IERC20 depositToken = _tokens[0];
        require(isAcceptedToken(newBubble, depositToken), "Token not accepted");
        require(depositToken.transferFrom(msg.sender, address(this), initialDeposit), "Initial deposit failed");
        newBubble.popPool[depositToken] += initialDeposit;
        
        userBubbleCount[msg.sender]++;
    }

    function isDuplicateBubble(IERC20[] memory _tokens, uint256 _popProbability) internal view returns (bool) {
        for (uint256 i = 0; i < bubbles.length; i++) {
            Bubble storage existingBubble = bubbles[i];
            if (existingBubble.isActive && existingBubble.popProbability == _popProbability && compareTokens(existingBubble.acceptedTokens, _tokens)) {
                return true;
            }
        }
        return false;
    }

    function compareTokens(IERC20[] storage tokens1, IERC20[] memory tokens2) internal view returns (bool) {
        if (tokens1.length != tokens2.length) {
            return false;
        }
        bool[] memory matched = new bool[](tokens2.length);
        for (uint256 i = 0; i < tokens1.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < tokens2.length; j++) {
                if (!matched[j] && address(tokens1[i]) == address(tokens2[j])) {
                    matched[j] = true;
                    found = true;
                    break;
                }
            }
            if (!found) {
                return false;
            }
        }
        return true;
    }

    function isAcceptedToken(Bubble storage bubble, IERC20 token) internal view returns (bool) {
        for (uint256 i = 0; i < bubble.acceptedTokens.length; i++) {
            if (address(bubble.acceptedTokens[i]) == address(token)) {
                return true;
            }
        }
        return false;
    }

    function deposit(uint256 bubbleId, IERC20 token) external {
        Bubble storage bubble = bubbles[bubbleId];
        require(bubble.isActive, "Bubble has popped!");
        require(isAcceptedToken(bubble, token), "Token not accepted");
        require(token.allowance(msg.sender, address(this)) >= bubble.depositPrice, "Insufficient allowance");
        require(token.transferFrom(msg.sender, address(this), bubble.depositPrice), "Deposit failed");

        uint256 devFee = (bubble.depositPrice * 2) / 100;
        uint256 userContribution = bubble.depositPrice - devFee;
        bubble.popPool[token] += userContribution;
        require(token.transfer(developerAddress, devFee), "Developer fee transfer failed");

        bubble.depositCount++;
        if (shouldPop(bubble)) {
            triggerPop(bubbleId, msg.sender);
        }

        emit Deposited(bubbleId, msg.sender, bubble.depositPrice, address(token));
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
        
        for (uint256 i = 0; i < bubble.acceptedTokens.length; i++) {
            IERC20 token = bubble.acceptedTokens[i];
            uint256 poolAmount = bubble.popPool[token];

            if (poolAmount > 0) {
                uint256 popAmount = (poolAmount * 50) / 100;
                uint256 burnAmount = (poolAmount * bubble.burnPercentage) / 10000;
                uint256 creatorReward = bubble.popPool[token] - popAmount - burnAmount;
                bubble.popPool[token] = 0;
                require(token.transfer(user, popAmount), "Pop payout failed");
                if (burnAmount > 0) {
                    require(token.transfer(address(0), burnAmount), "Burn failed");
                }
                require(token.transfer(bubble.bubbleCreator, creatorReward), "Creator reward failed");
                emit Popped(bubbleId, user, popAmount, address(token));
            }
        }
        reusableIndexes.push(bubbleId);
        userBubbleCount[bubble.bubbleCreator]--;
    }
}
