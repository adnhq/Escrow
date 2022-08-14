// SPDX-License-Identifier: MIT

pragma solidity =0.8.15;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract Escrow is Ownable, IERC721Receiver {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;
    Counters.Counter private _tradeIds;

    // Escrow fees paid by trader category on each NFT
    uint public eliteFee = 1e18;
    uint public regularFee = 2e18; 
    uint public nonHolderFee = 3e18;

    IERC721 private constant ELITE = IERC721(0x5B38Da6a701c568545dCfcB03FcB875f56beddC4);
    IERC721 private constant REGULAR = IERC721(0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2);

    IERC20 private constant TOKEN = IERC20(0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db);
    
    bool public paused = false;

    /// @notice Represents a single NFT as a trade item
    struct Item {
        /// @notice NFT contract address
        address nft;

        /// @notice Token id of NFT
        uint tokenId;
    }
    
    struct Trade {
        /// @notice Trade initiator address
        address trader0;

        /// @notice Trade fulfiller address
        address trader1;

        /// @notice Items to be traded by trader0/initiator
        Item[] items0;

        /// @notice Items to be traded by trader1/fulfiller
        Item[] items1;

        /// @notice Trade ongoing marker
        bool active;
    }

    mapping(uint => Trade) private _idToTrade; 
    
    event TradeInitiated(uint indexed tradeId, address indexed trader0, address indexed trader1, uint creationTime);
    event TradeCompleted(uint indexed tradeId, uint completionTime);

    modifier notPaused() {
        require(paused == false, "Escrow: contract paused");
        _;
    }

    /// @dev Fetches data for a specific trade
    /// @param tradeId ID of trade to retrieve data about
    /// @return Trade data of the given ID
    function fetchTradeData(uint tradeId) external view returns (Trade memory) {
        return _idToTrade[tradeId];
    }

    /// @notice Creates a new trade
    /// @param _trader1 address of the person to perform the trade with
    /// @param _items0 item(s) the caller will trade
    /// @param _items1 item(s) the other person will trade
    /// @return Trade ID of the newly created trade
    function startTrade( 
        address _trader1,
        Item[] calldata _items0,
        Item[] calldata _items1
    ) external notPaused returns (uint) {
        require(_trader1 != address(0), "Escrow: trader cannot be zero address");
        require(_items0.length != 0 && _items1.length != 0, "Escrow: invalid items");
        _tradeIds.increment();
        uint currentId = _tradeIds.current();
        Trade storage trade = _idToTrade[currentId];

        trade.trader0 = msg.sender;
        trade.trader1 = _trader1;
        trade.active = true;

        _takeFee(_items0.length + _items1.length);

        for(uint i; i < _items0.length; i++) {
            if(_items0[i].nft == address(0)) 
                revert("Escrow: contract cannot be zero address");
            else {
                trade.items0.push(_items0[i]);
                IERC721(_items0[i].nft).safeTransferFrom(msg.sender, address(this), _items0[i].tokenId);
            }       
        }

        for(uint j; j < _items1.length; j++) {
            if(_items1[j].nft == address(0)) 
                revert("Escrow: contract cannot be zero address");
            else 
                trade.items1.push(_items1[j]);     
        }

        emit TradeInitiated(currentId, msg.sender, _trader1, block.timestamp);
        return currentId;
    }
    
    /// @notice Fulfills an active trade 
    /// @dev Transfers items between both parties
    /// @param tradeId ID of trade to fulfill
    function completeTrade(uint tradeId) external notPaused {
        Trade memory trade = _idToTrade[tradeId];
        require(msg.sender == trade.trader1, "Escrow: must be designated trader");
        require(trade.active, "Escrow: trade not active");

        _idToTrade[tradeId].active = false;

        _takeFee(trade.items0.length + trade.items1.length);

        for(uint i; i < trade.items1.length; i++) {
            IERC721(trade.items1[i].nft).safeTransferFrom(msg.sender, trade.trader0, trade.items1[i].tokenId);
        }

        for(uint j; j < trade.items0.length; j++) {
            IERC721(trade.items0[j].nft).safeTransferFrom(address(this), msg.sender, trade.items0[j].tokenId);
        }

        emit TradeCompleted(tradeId, block.timestamp);
    }
    
    /// @notice Cancels a trade in case of an unresponsive trader
    /// @notice Returns initially received items to the caller/trade creator
    /// @param tradeId ID of the trade to cancel
    function cancelTrade(uint tradeId) external notPaused {
        Trade memory trade = _idToTrade[tradeId];
        require(msg.sender == trade.trader0, "Escrow: must be trade creator");
        require(trade.active, "Escrow: trade not active");

        delete _idToTrade[tradeId];

        for(uint i; i < trade.items0.length; i++) {
            IERC721(trade.items0[i].nft).safeTransferFrom(address(this), msg.sender, trade.items0[i].tokenId);
        }
    }

    /// @dev Calculates and takes escrow fee from caller
    function _takeFee(uint totalItems) private {
        uint fee;
        if(ELITE.balanceOf(msg.sender) > 0) 
            fee = eliteFee;
        else if(REGULAR.balanceOf(msg.sender) > 0)
            fee = regularFee;
        else 
            fee = nonHolderFee;
        
        TOKEN.safeTransferFrom(msg.sender, address(this), totalItems * fee);
    }

    /* |--- ONLY OWNER ---| */

    /// @notice Transfers TOKEN token balance of the contract to the owner
    function collectFee() external onlyOwner {
        TOKEN.transfer(msg.sender, TOKEN.balanceOf(address(this))); 
    }

    /// @notice Change escrow fee for elite members
    /// @param _eliteFee new elite fee
    function setEliteFee(uint _eliteFee) external onlyOwner {
        eliteFee = _eliteFee;
    }

    /// @notice Change escrow fee for regular members
    /// @param _regularFee new regular fee
    function setRegularFee(uint _regularFee) external onlyOwner {
        regularFee = _regularFee;
    }

    /// @notice Change escrow fee for non holders
    /// @param _nonHolderFee new non holder fee
    function setNonHolderFee(uint _nonHolderFee) external onlyOwner {
        nonHolderFee = _nonHolderFee;
    }

    /// @notice Pauses contract functionality
    function pause() external onlyOwner {
        paused = true;
    }

    /// @notice Unpauses contract functionality
    function unpause() external onlyOwner {
        paused = false;
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        return this.onERC721Received.selector;
    }
    
}
