pragma solidity ^0.6.0;

import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/GSN/Context.sol";


/***************
 POLL CONTRACT 
***************/

contract PeepsPoll {
    
    using SafeMath for uint256;
    
  
   //GLOBAL CONSTANTS 
    uint256 public periodDuration; // set length of period for a poll (1 = 1 second)
    uint256 public pollLength; // set length of the poll in periods 
    uint256 public startTime; // set start time for poll
    address public pollster; // creator of the poll
    address public voteToken; // token used to decide voting weight
    
    // HARD-CODED LIMITS
    // Set arbitrarily because of gas limits...you know 
    uint256 constant MAX_VOTERS = 100; // maximum number of voters
    uint256 constant MAX_OPTIONS = 25; // maximum number of options 
    
    //EVENTS 
    event createPoll(uint256 summoningTime, uint256 periodDuration, uint256 pollLength, address votingToken, address indexed pollster);
    event SubmitVote(uint256 optionID, uint256 voteWeight, address indexed voterAddress);

    //This is a type for a voter.    
     struct Voter {
        bool voted;  // if true, that person already voted
        address delegate; // person delegated to
        uint voteWeight;   // index of the voted proposal
    }
    
    //This is a type for a single vote. 
     struct Vote {
        uint256 optionID;
        uint256 tokensVoted;
    }

    // This is a type for a single option.
    struct Option {
        uint256 forVotes; // number of accumulated votes
        string name;   // short name
        string details; // details can be string or link
        mapping(address => Vote) votesByVoter;  // all the actual votes
        address[] voters;
    }
    
    struct WinningOption {
        Option option;  // the original proposal
        uint optionID;  // its index in the option list
        uint totalVotes; // its total votes
        bool exists; // always true
    }
    
    //MODIFIERS 
     modifier onlyPollster() {
        require(msg.sender == pollster, "Error: only the pollster can take this action");
        _;
    }

    // This declares a state variable that
    // stores a `Voter` struct for each possible address.
    mapping(address => Voter) public voters;

    // A dynamically-sized array of `Option` structs.
    Option[] public options;

    /// Create a poll 
    constructor(
        address _pollster,
        address _voteToken,
        uint256 _periodDuration,
        uint256 _pollLength 

        ) public {
        pollster = msg.sender;
        voters[pollster].weight = 1;

        // For each of the provided proposal names,
        // create a new proposal object and add it
        // to the end of the array.
        for (uint i = 0; i < proposalNames.length; i++) {
            // `Proposal({...})` creates a temporary
            // Proposal object and `proposals.push(...)`
            // appends it to the end of `proposals`.
            proposals.push(Proposal({
                name: proposalNames[i],
                voteCount: 0
            }));
        }
    }

    // Give `voter` the right to vote on this ballot.
    // May only be called by `chairperson`.
    function giveRightToVote(address voter) public {
        require(
            msg.sender == pollster,
            "Only chairperson can give right to vote."
        );
        require(
            !voters[voter].voted,
            "The voter already voted."
        );
        require(voters[voter].weight == 0);
        voters[voter].weight = 1;
    }

    /// Delegate your vote to the voter `to`.
    function delegate(address to) public {
        // assigns reference
        Voter storage sender = voters[msg.sender];
        require(!sender.voted, "You already voted.");

        require(to != msg.sender, "Self-delegation is disallowed.");

        while (voters[to].delegate != address(0)) {
            to = voters[to].delegate;

            // We found a loop in the delegation, not allowed.
            require(to != msg.sender, "Found loop in delegation.");
        }

        // Since `sender` is a reference, this
        // modifies `voters[msg.sender].voted`
        sender.voted = true;
        sender.delegate = to;
        Voter storage delegate_ = voters[to];
        if (delegate_.voted) {
            // If the delegate already voted,
            // directly add to the number of votes
            proposals[delegate_.vote].voteCount += sender.weight;
        } else {
            // If the delegate did not vote yet,
            // add to her weight.
            delegate_.weight += sender.weight;
        }
    }

    /// Give your vote (including votes delegated to you)
    /// to proposal `proposals[proposal].name`.
    function vote(uint proposal) public {
        Voter storage sender = voters[msg.sender];
        require(sender.weight != 0, "Has no right to vote");
        require(!sender.voted, "Already voted.");
        sender.voted = true;
        sender.vote = proposal;

        // If `proposal` is out of the range of the array,
        // this will throw automatically and revert all
        // changes.
        proposals[proposal].voteCount += sender.weight;
    }

    /// @dev Computes the winning proposal taking all
    /// previous votes into account.
    function winningProposal() public view
            returns (uint winningProposal_)
    {
        uint winningVoteCount = 0;
        for (uint p = 0; p < proposals.length; p++) {
            if (proposals[p].voteCount > winningVoteCount) {
                winningVoteCount = proposals[p].voteCount;
                winningProposal_ = p;
            }
        }
    }

    // Calls winningProposal() function to get the index
    // of the winner contained in the proposals array and then
    // returns the name of the winner
    function winnerName() public view
            returns (bytes32 winnerName_)
    {
        winnerName_ = proposals[winningProposal()].name;
    }  
    
}


/***************
 POLL FACTORY 
***************/

contract PeepsPollFactory {
    // Built by Peeps Democracy for fun ~ Use at own risk!
    uint8 public version = 1;
    
    // factory settings
    uint256 public pollTax;
    address payable public peepsWallet; 
    
    //array of polls 

    PeepsPoll private Poll;
    address[] public polls; 
    
    //events
    event newPoll(address indexed Poll, address indexed pollster);
    
    constructor (
        uint256 _pollTax, 
        address payable _peepsWallet) public 
    {
        pollTax = _pollTax;
        peepsWallet = _peepsWallet;
    }
    
    function newPeepsPoll( // public can issue stamped lex token for factory ether (Ξ) fee
    string memory _pollName, 
    address payable[] memory _pollTokens,
	address payable[] memory _pollTakers,
	address _pollster) payable public {
	require(msg.value == pollTax);
	require(peepsWallet != address(0));
        
        Poll = (new PeepsPoll).value(msg.value)(
            _pollName, 
            _pollTokens, 
            _pollTakers,
            _pollster);
        
        polls.push(address(Poll));
        address(peepsWallet).transfer(msg.value);
        emit newPoll(address(Poll), _pollster);
    }
    
    function getPollCount() public view returns (uint256 PollCount) {
        return polls.length;
    }
}    