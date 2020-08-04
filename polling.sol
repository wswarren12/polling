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
    uint256 public creationTime; // needed to determine the current period
    
    // HARD-CODED LIMITS
    // Set arbitrarily because of gas limits...you know 
    uint256 constant MAX_VOTERS = 1000; // maximum number of voters
    uint256 constant MAX_OPTIONS = 20; // maximum number of options 
    
    
    //EVENTS 
    event PeepsPollingCreated(address pollster, address voteToken, uint256 periodDuration);
    event RegisterVoters(address[] newVoters, uint256[] voterTokens);
    event CreateBallot(uint256 proposalIndex, uint256 startingPeriod, uint256 pollLength, string[] options, string details);
    event SubmitVote(uint256 proposalIndex, address voter, string option, uint256 tokensSpent, uint256 quadraticVotes);
    event UpdateDelegateKey(address sender, address newDelegateKey);

    //This is a type for a voter.    
     struct Voter {
        address delegate; // allows for user to delegate vote to a different personal wallet address 
        uint256 tokenBalance; // index of the voted proposal
        uint256 highestIndexVote; // highest ballot index # on which the member voted 
        uint256 penaltyBox; // set to the period in which the member is placed in the penalty box
        bool exists; // always true once a member has been created
      
    }
    
    struct userBallot {
        address owner;
        uint256[] votes;
        uint256[] quadraticVotes;
        string[] options;
    }
    
    struct Ballot {
        string[] options; // list of options to include in a ballot
        uint256[] totalVotes; // total votes each candidate received
        uint256[] totalQuadraticVotes; // calculation of quadratic votes for each candidate
        uint256 startingPeriod; // the period in which voting can start for this proposal
        uint256 pollLength; // the period when the proposal closes
        string winningProposal; // name of winning option
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
    //  dynamically-sized array of `Ballot` structs.
    Ballot[] public ballotQueue;


    constructor(
        address _pollster,
        address _voteToken,
        uint256 _periodDuration
        ) public {
            

        
        voteToken = _voteToken;
        pollster = _pollster;
        voteToken = _voteToken;
        periodDuration = _periodDuration;
        creationTime = now; 
        
        emit PeepsPollingCreated(_pollster, _voteToken, _periodDuration);
    }
    
    /***************
    VOTER REGISTRATION 
    ***************/
    
    // registers new voters, set voterTokens to 0 if you don't want to mint new tokens for that voter
    function registerVoters(address[] newVoters, uint256[] voterTokens) external onlyPollster {
        require(newvoters.length == voterTokens.length, "your arrays do not match in length");
        
        for (uint256 i = 0; i < newVoters.length; i++) {
            _registerVoter(newVoters[i], voterToken[i]);
        }
        
        emit RegisterVoters(newVoters, voterTokens);
        
    }
        
    function _registerVoter(address newVoter, uint256 voterTokens) internal {  // if new member is already taken by a member's delegateKey, reset it to their member address
        if (voters[voterAddressByDelegateKey[newVoter]].exists == true) {
            address voterToOverride = voterAddressByDelegateKey[newVoter];
            voterAddressByDelegateKey[voterToOverride] = voterToOverride;
            voters[voterToOverride].delegateKey = voterToOverride;
        }
        
        if (voterTokens > 0) {
            require(IERC20(voteToken).approve(address(this), voterTokens), "approval failed");
            require(IERC20(voteToken).tranferFrom(address(this), newVoter, voterTokens), "token transfer failed");
        }
        
        voters[newVoter] = Voter({
            delegateKey : newVoter,
            exists : true,
            tokenBalance : setUserTokenBalance(newVoter),
            highestIndexYesVote : 0,
            penaltyBox : 0
        });

        voterAddressByDelegateKey[newVoter] = newVoter;
    }
    
    /*****************
    BALLOT FUNCTIONS
    *****************/

    function createBallot(
        string[] memory options,
        uint256 pollLength,
        string memory details
    )
        public onlyPollster {
        require(options.length > 0, "Need to have at least 1 option.");
        require(options.length < MAX_OPTIONS);
        for (uint i=0; i < options.length; i++) {
            require(options[i] != "", "Option cannot be blank");
        }

        // compute startingPeriod for ballot
        uint256 startingPeriod = max(
            getCurrentPeriod(),
            proposalQueue.length == 0 ? 0 : proposalQueue[proposalQueue.length.sub(1)].startingPeriod
        ).add(1);

        // create proposal ...
        
        Proposal memory proposal = Proposal({
            proposer: msg.sender,
            options: options,
            totalVotes: new uint256[](options.length),
            totalQuadraticVotes: new uint256[](options.length),
            startingPeriod: startingPeriod,
            pollLength: pollLength,
            winningProposal: "",
            tabulated: false,
            aborted: false,
            details: details
        });

        // ... and append it to the queue
        proposalQueue.push(proposal);

        uint256 proposalIndex = proposalQueue.length.sub(1);  
        
        emit CreateBallot(proposalIndex, startingPeriod, pollLength, options, details);
    }
    
    
     function submitVote(uint256 proposalIndex, string option, uint256 votes) public onlyDelegate {
        
        address voterAddress = voterAddressByDelegateKey[msg.sender];
        Voter storage voter = voters[voterAddress];
        require(proposalIndex < proposalQueue.length, "Ballot does not exist");
        
        Proposal storage proposal = proposalQueue[proposalIndex];
        
        require(votes > 0, "At least one vote must be cast");
        require(getCurrentPeriod() >= ballot.startingPeriod, "Voting period has not started");
        require(!hasVotingPeriodExpired(ballotIndex), "Voting period has expired");
        require(!ballot.aborted, "Ballot has been aborted");

        Ballot storage memberBallot = ballot.votesByVoter[voterAddress];

        // store vote
        uint256 totalVotes;
        uint256 newVotes;
        uint256 quadraticVotes;

        //Set empty array for new ballot
        if (memberBallot.votes.length == 0) {
            memberBallot.votes = new uint256[](proposal.candidates.length);
            memberBallot.candidate = new address[](proposal.candidates.length);
            memberBallot.quadraticVotes = new uint256[](proposal.candidates.length);
        }
        for (uint i = 0; i < proposal.candidates.length; i++) {
            if (proposal.candidates[i] == candidate) {
                newVotes = memberBallot.votes[i].add(votes);
                uint256 prevquadraticVotes = memberBallot.quadraticVotes[i];
                quadraticVotes = sqrt(newVotes);
                proposal.totalVotes[i] = proposal.totalVotes[i].add(votes);
                proposal.totalQuadraticVotes[i] = proposal.totalQuadraticVotes[i].sub(prevquadraticVotes).add(quadraticVotes);
                memberBallot.candidate[i] = candidate;
                memberBallot.votes[i] = newVotes;
                memberBallot.quadraticVotes[i] = quadraticVotes;
                if (proposalIndex > member.highestIndexVote) {
                    member.highestIndexVote = proposalIndex;
                }           
            } 
            totalVotes = totalVotes.add(memberBallot.votes[i]);
        }

        require(totalVotes <= member.shares, "QuadraticMoloch::submitVote - not enough shares to cast this quantity of votes");

        emit SubmitVote(proposalIndex, msg.sender, memberAddress, option, votes, quadraticVotes);
    }

    function processProposal(uint256 proposalIndex) public {
        require(proposalIndex < proposalQueue.length, "Moloch::processProposal - proposal does not exist");
        Proposal storage proposal = proposalQueue[proposalIndex];

        require(getCurrentPeriod() >= proposal.startingPeriod.add(votingPeriodLength).add(gracePeriodLength), "Moloch::processProposal - proposal is not ready to be processed");
        require(proposal.processed == false, "Moloch::processProposal - proposal has already been processed");
        require(proposalIndex == 0 || proposalQueue[proposalIndex.sub(1)].processed, "Moloch::processProposal - previous proposal must be processed");

        proposal.processed = true;
        totalSharesRequested = totalSharesRequested.sub(proposal.sharesRequested);

        // Get elected candidate
        uint256 largest = 0;
        uint elected = 0;
        require(proposal.totalVotes.length > 0, "QuadraticMoloch::processProposal - this proposal has not received any votes.");
        bool didPass = true;
        for (uint i = 0; i < proposal.totalVotes.length; i++) {
            if (quadraticMode) {
                require(proposal.totalQuadraticVotes[i] != largest, "QuadraticMoloch::processProposal - this proposal has no winner" );
                if (proposal.totalQuadraticVotes[i] > largest) {
                    largest = proposal.totalQuadraticVotes[i];
                    elected = i;
                }
            } else if (proposal.totalVotes[i] > largest) {
                largest = proposal.totalVotes[i];
                elected = i;
            }
        
            address electedCandidate = proposal.candidates[i];

            // Make the proposal fail if the dilutionBound is exceeded
            if (totalShares.mul(dilutionBound) < proposal.maxTotalSharesAtYesVote) {
                didPass = false;
            }

            // PROPOSAL PASSED
            if (didPass && !proposal.aborted) {

                proposal.didPass = true;
                proposal.electedCandidate = electedCandidate;

                // if the elected candidate is already a member, add to their existing shares
                if (members[electedCandidate].exists) {
                    members[electedCandidate].shares = members[electedCandidate].shares.add(proposal.sharesRequested);

                // the applicant is a new member, create a new record for them
                } else {
                    // if the applicant address is already taken by a member's delegateKey, reset it to their member address
                    if (members[memberAddressByDelegateKey[electedCandidate]].exists) {
                        address memberToOverride = memberAddressByDelegateKey[electedCandidate];
                        memberAddressByDelegateKey[memberToOverride] = memberToOverride;
                        members[memberToOverride].delegateKey = memberToOverride;
                    }

                    // use elected candidate address as delegateKey by default
                    members[electedCandidate] = Member(electedCandidate, proposal.sharesRequested, true, 0);
                    memberAddressByDelegateKey[electedCandidate] = electedCandidate;
                }

                // mint new shares
                totalShares = totalShares.add(proposal.sharesRequested);

                // transfer tokens to guild bank from winner
                require(
                approvedToken.transfer(address(guildBank), proposal.tokenTribute),
                "Moloch::processProposal - token transfer to guild bank failed"
                );
                // return tokens to other candidates
                for (uint k = 0; k < proposal.candidates.length; k++) {
                    if (proposal.candidates[k] != electedCandidate) {
                        require(
                        approvedToken.transfer(proposal.candidates[k], proposal.tokenTribute),
                        "Moloch::processProposal - token transfer to guild bank failed"
                        );
                    }
                }

            // PROPOSAL FAILED OR ABORTED
            } else {
                // return all tokens to the candidates
                for (uint z = 0; z < proposal.candidates.length; z++) {
                    require(
                    approvedToken.transfer(proposal.candidates[z], proposal.tokenTribute),
                    "Moloch::processProposal - token transfer to guild bank failed"
                    );
                }
            }

            // send msg.sender the processingReward
            require(
                approvedToken.transfer(msg.sender, processingReward),
                "Moloch::processProposal - failed to send processing reward to msg.sender"
            );

            // return deposit to proposer (subtract processing reward)
            require(
                approvedToken.transfer(proposal.proposer, proposalDeposit.sub(processingReward)),
                "Moloch::processProposal - failed to return proposal deposit to proposer"
            );

            emit TabulateBallot(ballotIndex, winningOption);
        }
    }

    
    /***************
    VOTER HELPER FUNCTIONS
    ***************/
    
    function getVoterTokenBalance(address voter) external view {
        require(voters[voter].exists == true, "voter does not exist yet");
        require(IERC20(voteToken).balanceOf(voter), "no token balance visible");
    }
    
    function setVoterTokenBalance(address voter) internal {
        require(voters[msg.sender].exists == true, "no voter on record");
        voters[voter].tokenBalance == IERC20(voteToken).balanceOf(voter);
    }
    
    function updateDelegateKey(address newDelegateKey) external {
        require(voters[msg.sender].tokenBalance > 0, "not a current voter");
        require(newDelegateKey != address(0), "newDelegateKey zeroed");

        // skip checks if member is setting the delegate key to their member address
        if (newDelegateKey != msg.sender) {
            require(voters[newDelegateKey].exists == false, "cannot overwrite members");
            require(voters[voterAddressByDelegateKey[newDelegateKey]].exists == false, "cannot overwrite keys");
        }

        Voter storage voter = voters[msg.sender];
        voterAddressByDelegateKey[voter.delegateKey] = address(0);
        voterAddressByDelegateKey[newDelegateKey] = msg.sender;
        voter.delegateKey = newDelegateKey;

        emit UpdateDelegateKey(msg.sender, newDelegateKey);
    }
    
    function getCurrentPeriod() public view returns (uint256) {
        return now.sub(summoningTime).div(periodDuration);
    }
    
    function hasVotingPeriodExpired(uint256 proposalIndex) public view returns (bool) {
        Proposal storage proposal = proposalQueue[proposalIndex];
        return getCurrentPeriod() >= proposal.startingPeriod + proposal.pollLength;
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