pragma solidity ^0.6.0;

import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/GSN/Context.sol";


/***************
 POLL CONTRACT 
***************/

contract PollingStation {
    
    using SafeMath for uint256;
    
   //GLOBAL CONSTANTS 
    uint256 public periodDuration; // set length of period for a poll (1 = 1 second)
    uint256 public pollLength; // set length of the poll in periods 
    uint256 public startTime; // set start time for poll
    uint256 public creationTime; // needed to determine the current period
    address public pollster; // creator of the poll
    address public voteToken; // token used to decide voting weight
    string public pollingStationName;
    
    // HARD-CODED LIMITS
    // Set arbitrarily because of gas limits...you know 
    uint256 constant MAX_VOTERS = 1000; // maximum number of voters
    uint256 constant MAX_OPTIONS = 20; // maximum number of options 
    
    
    //EVENTS 
    event PeepsPollingCreated(address pollster, address voteToken, uint256 periodDuration);
    event RegisterVoters(address[] newVoters, uint256[] voterTokens);
    event CreateBallot(uint256 proposalIndex, uint256 startingPeriod, uint256 pollLength, bytes32[] options, string details);
    event SubmitVote(uint256 proposalIndex, address voter, string option, uint256 tokensSpent, uint256 quadraticVotes);
    event TabulateBallot(uint256 ballotIndex, string winningOption);
    event Abort(uint256 ballotIndex);
    event UpdateDelegateKey(address sender, address newDelegateKey);
    

    //This is a type for a voter.    
     struct Voter {
        address delegate; // allows for user to delegate vote to a different personal wallet address 
        uint256 tokenBalance; // index of the voted proposal
        uint256 highestIndexVote; // highest ballot index # on which the voter voted 
        uint256 penaltyBox; // set to the period in which the voter is placed in the penalty box
        bool exists; // always true once a voter has been created
    }
    
    struct userBallot {
        address owner;
        uint256[] votes;
        uint256[] quadraticVotes;
        string[] options;
    }
    
    struct Ballot {
        bytes32[] options; // list of options to include in a ballot
        uint256[] totalVotes; // total votes each candidate received
        uint256[] totalQuadraticVotes; // calculation of quadratic votes for each candidate
        uint256 startingPeriod; // the period in which voting can start for this proposal
        uint256 pollLength; // the period when the proposal closes
        bytes32 winningOption; // name of winning option
        bool tabulated; // true only if the proposal has been processed
        bool aborted; // true only if applicant calls "abort" fn before end of voting period
        string details; // proposal details - could be IPFS hash, plaintext, or JSON
        mapping (address => userBallot) votesByVoter; // list of options and corresponding votes
    }
    
    
    //MODIFIERS 
     modifier onlyPollster() {
        require(msg.sender == pollster, "Error: only the pollster can take this action");
        _;
    }

    // stores a `Voter` struct for each voter address.
    mapping(address => Voter) public voters;
    mapping(address => address) public voterAddressByDelegateKey;

   // mapping of proposals for proposalId
    mapping(uint256 => Ballot) public ballots;
    Ballot[] public ballotQueue;


    constructor(
        address _pollster,
        address _voteToken,
        uint256 _periodDuration,
        string  memory _pollingStationName
        ) public {
        
        voteToken = _voteToken;
        pollster = _pollster;
        voteToken = _voteToken;
        periodDuration = _periodDuration;
        pollingStationName = _pollingStationName;
        creationTime = now; 
        
        emit PeepsPollingCreated(_pollster, _voteToken, _periodDuration);
    }
    
    /***************
    VOTER REGISTRATION 
    ***************/
    
    // registers new voters, set voterTokens to 0 if you don't want to mint new tokens for that voter
    function registerVoters(address[] memory newVoters, uint256[] memory voterTokens) external onlyPollster {
        require(newVoters.length == voterTokens.length, "your arrays do not match in length");
        
        for (uint256 i = 0; i < newVoters.length; i++) {
            _registerVoter(newVoters[i], voterTokens[i]);
        }
        
        emit RegisterVoters(newVoters, voterTokens);
    }
        
    function _registerVoter(address newVoter, uint256 voterTokens) internal {  
        // if new voter is already taken by a voters's delegateKey, reset it to their voter address
        if (voters[voterAddressByDelegateKey[newVoter]].exists == true) {
            address voterToOverride = voterAddressByDelegateKey[newVoter];
            voterAddressByDelegateKey[voterToOverride] = voterToOverride;
            voters[voterToOverride].delegate = voterToOverride;
        }
        
        uint256 allocatedTokens = voterTokens;
        
        if (voterTokens > 0) {
            require(IERC20(voteToken).approve(address(this), voterTokens), "approval failed");
            require(IERC20(voteToken).transferFrom(address(this), newVoter, allocatedTokens), "token transfer failed");
        }
        
        
        
        voters[newVoter] = Voter({
        delegate: newVoter,// allows for user to delegate vote to a different personal wallet address 
        tokenBalance: 0, // index of the voted proposal
        highestIndexVote: 0, // highest ballot index # on which the voter voted 
        penaltyBox: 0, // set to the period in which the voter is placed in the penalty box
        exists: true // always true once a voter has been created
        });

        voterAddressByDelegateKey[newVoter] = newVoter;
        uint256 initialTokenBalance = getVoterTokenBalance(newVoter);
        voters[newVoter].tokenBalance = initialTokenBalance;
    }
    
    /*****************
    BALLOT FUNCTIONS
    *****************/

    function createBallot(
        bytes32[] memory options,
        uint256 _startingPeriod,
        uint256 _pollLength,
        string memory details
    )
        public onlyPollster {
        require(options.length > 0, "Need to have at least 1 option.");
        require(options.length < MAX_OPTIONS);
        for (uint i=0; i < options.length; i++) {
            require(options[i] != 0, "Option cannot be blank");
        }
        require(_startingPeriod > getCurrentPeriod().add(1), "must set starting period in future");


        // create new ballot for some votes ...
        
        /*
        bytes32[] options; // list of options to include in a ballot
        uint256[] totalVotes; // total votes each candidate received
        uint256[] totalQuadraticVotes; // calculation of quadratic votes for each candidate
        uint256 startingPeriod; // the period in which voting can start for this proposal
        uint256 pollLength; // the period when the proposal closes
        string winningOption; // name of winning option
        bool tabulated; // true only if the proposal has been processed
        bool aborted; // true only if applicant calls "abort" fn before end of voting period
        string details; // proposal details - could be IPFS hash, plaintext, or JSON
        mapping (address => userBallot) votesByVoter; // list of options and corresponding votes
        */
        
        Ballot memory ballot = Ballot({
            options: options,
            totalVotes: new uint256[](options.length),
            totalQuadraticVotes: new uint256[](options.length),
            startingPeriod: _startingPeriod,
            pollLength: _pollLength,
            winningOption: 0,
            tabulated: false,
            aborted: false,
            details: details
        });

        // ... and append it to the queue
       ballotQueue.push(ballot);

        uint256 ballotIndex = ballotQueue.length.sub(1);  
        
        emit CreateBallot(ballotIndex, _startingPeriod, _pollLength, options, details);
    }
    
    
     function submitVote(uint256 ballotIndex, string memory option, uint256 votes) public  {
        require(voters[voterAddressByDelegateKey[msg.sender]].exists = true, "not a voter");
        
        address voterAddress = voterAddressByDelegateKey[msg.sender];
        Voter storage voter = voters[voterAddress];
        require(ballotIndex < ballotQueue.length, "Ballot does not exist");
        
        Ballot storage ballot = ballotQueue[ballotIndex];
        
        require(votes > 0, "At least one vote must be cast");
        require(getCurrentPeriod() >= ballot.startingPeriod, "Voting period has not started");
        require(!hasVotingPeriodExpired(ballotIndex), "Voting period has expired");
        require(!ballot.aborted, "Ballot has been aborted");

        userBallot storage voterBallot = ballot.votesByVoter[voterAddress];

        // store vote
        uint256 totalVotes;
        uint256 newVotes;
        uint256 quadraticVotes;

        //Set empty array for new ballot
        if (voterBallot.votes.length == 0) {
            voterBallot.votes = new uint256[](ballot.options.length);
            voterBallot.option = new string[](ballot.options.length);
            voterBallot.quadraticVotes = new uint256[](ballot.options.length);
        }
         
        for (uint i = 0; i < ballot.options.length; i++) {
            if (ballot.options[i] == option) {
                newVotes = userBallot.votes[i].add(votes);
                uint256 prevquadraticVotes = userBallot.quadraticVotes[i];
                quadraticVotes = sqrt(newVotes);
                ballot.totalVotes[i] = ballot.totalVotes[i].add(votes);
                ballot.totalQuadraticVotes[i] = ballot.totalQuadraticVotes[i].sub(prevquadraticVotes).add(quadraticVotes);
                voterBallot.option[i] = option;
                voterBallot.votes[i] = newVotes;
                voterBallot.quadraticVotes[i] = quadraticVotes;
                if (ballotIndex > voter.highestIndexVote) {
                    voter.highestIndexVote = ballotIndex;
                }           
            } 
            totalVotes = totalVotes.add(voterBallot.votes[i]);
        }

        require(totalVotes <= voter.tokenBalance, "Not enough tokens to cast this quantity of votes");
        require(IERC20(voteToken).tranfer(address(this), totalVotes), "vote token transfer failed");

        emit SubmitVote(ballotIndex, msg.sender, voterAddress, option, votes, quadraticVotes);
    }

    function tabulateBallot(uint256 ballotIndex) public onlyPollster {
        require(ballotIndex < ballotQueue.length, "Ballot does not exist");
        Ballot storage ballot = ballotQueue[ballotIndex];

        require(getCurrentPeriod() >= ballot.startingPeriod.add(ballot.pollLength), "Voting has not ended is not ready to be processed");
        require(ballot.tabulated == false, "Ballot has already been tabulated");
        require(ballotIndex == 0 || ballotQueue[ballotIndex.sub(1)].tabulated, "Previous ballot must be tabulated first");

       

        // Get favorite option
        uint256 largest = 0;
        uint chosen = 0;
        require(ballot.totalVotes.length > 0, "This ballot has not received any votes.");
        bool didPass = true;
        for (uint i = 0; i < ballot.totalVotes.length; i++) {
                require(ballot.totalQuadraticVotes[i] != largest, "This ballot has no winner" );
                if (ballot.totalQuadraticVotes[i] > largest) {
                    largest = ballot.totalQuadraticVotes[i];
                    chosen = i;
                }
                
            string memory winningOption = ballot.options[i]; 
            
             if (didPass && !ballot.aborted) {
                ballot.didPass = true;
                ballot.winningOption = winningOption;
            }  
        }
        
            string memory winningOption = ballot.winningOption;
            ballot.tabulated = true;

            emit TabulateBallot(ballotIndex, winningOption);
        }
        
     function abort(uint256 ballotIndex) public onlyPollster {
        require(ballotIndex < ballotQueue.length, "Moloch::abort - proposal does not exist");
        Ballot storage ballot = ballotQueue[ballotIndex];

        require(getCurrentPeriod() < ballot.startingPeriod, "Voting period cannot have started");
        require(!ballot.aborted, "Ballot must not have already been aborted");

        ballot.aborted = true;

        emit Abort(ballotIndex);
    }    

    
    /***************
    VOTER HELPER FUNCTIONS
    ***************/
    
    function getVoterTokenBalance(address voter) public view returns (uint256) {
        require(voters[voter].exists == true, "voter does not exist yet");
        require(IERC20(voteToken).balanceOf(voter) > 0, "no token balance");
        
        return IERC20(voteToken).balanceOf(voter);
        
    }
    
    function updateVoterTokenBalance(address voter) internal returns (uint256) {
        require(voters[msg.sender].exists == true, "no voter on record");
        voters[voter].tokenBalance == IERC20(voteToken).balanceOf(voter);
    }
    
    function updateDelegateKey(address newDelegateKey) external {
        require(voters[msg.sender].tokenBalance > 0, "not a current voter");
        require(newDelegateKey != address(0), "newDelegateKey zeroed");

        // skip checks if voter is setting the delegate key to their voter address
        if (newDelegateKey != msg.sender) {
            require(voters[newDelegateKey].exists == false, "cannot overwrite voters");
            require(voters[voterAddressByDelegateKey[newDelegateKey]].exists == false, "cannot overwrite keys");
        }

        Voter storage voter = voters[msg.sender];
        voterAddressByDelegateKey[voter.delegateKey] = address(0);
        voterAddressByDelegateKey[newDelegateKey] = msg.sender;
        voter.delegateKey = newDelegateKey;

        emit UpdateDelegateKey(msg.sender, newDelegateKey);
    }
    
    function getCurrentPeriod() public view returns (uint256) {
        return now.sub(creationTime).div(periodDuration);
    }
    
    function hasVotingPeriodExpired(uint256 ballotIndex) public view returns (bool) {
        Ballot storage ballot = ballotQueue[ballotIndex];
        return getCurrentPeriod() >= ballot.startingPeriod + ballot.pollLength;
    }
    
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
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
    
    //events
    event NewPollingStation(address PollingStation, address pollster, address voteToken);
    
    constructor (
        uint256 _pollTax, 
        address payable _peepsWallet) public 
    {
        pollTax = _pollTax;
        peepsWallet = _peepsWallet;
    }
    
    function newPollingStation(
        address _pollster,
        address _voteToken,
        uint256 _periodDuration,
        string memory _pollingStationName) payable public {
        PollingStation = new PollingStation(
            _pollster, 
            _voteToken,
            _periodDuration,
            _pollingStationName);
        
        address(peepsWallet).transfer(msg.value);
        
        emit NewPollingStation(address(PollingStation), _pollster, _voteToken);
    }
    
}    