// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  CommunityGovernance
 * @author Your Name
 * @notice Token-weighted DAO governance. Members create proposals, vote with
 *         their ERC-20 governance tokens, and execute on-chain actions once
 *         quorum + majority are met.
 * @dev    Works with any ERC-20 governance token (e.g. OpenZeppelin ERC20Votes).
 *         This contract focuses on the governance logic; token contract is external.
 */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract CommunityGovernance {

    // ─────────────────────────────────────────────
    //  TYPES
    // ─────────────────────────────────────────────

    enum ProposalState {
        Active,
        Defeated,
        Succeeded,
        Executed,
        Cancelled
    }

    struct ProposalAction {
        address target;
        uint256 value;
        bytes   callData;
    }

    struct Proposal {
        uint256          id;
        address          proposer;
        string           title;
        string           description;        // plain text or IPFS CID
        ProposalAction[] actions;
        uint256          forVotes;
        uint256          againstVotes;
        uint256          abstainVotes;
        uint256          startBlock;
        uint256          endBlock;
        bool             executed;
        bool             cancelled;
    }

    // ─────────────────────────────────────────────
    //  CONSTANTS & IMMUTABLES
    // ─────────────────────────────────────────────

    /// @notice Percentage of total supply needed for quorum (5 %).
    uint256 public constant QUORUM_BPS    = 500;
    /// @notice Blocks a proposal stays open for voting (~2 days at 12 s/block).
    uint256 public constant VOTING_PERIOD = 14_400;
    /// @notice Minimum token balance to create a proposal (0.1 % of supply).
    uint256 public constant PROPOSAL_THRESHOLD_BPS = 10;

    IERC20 public immutable governanceToken;

    // ─────────────────────────────────────────────
    //  STATE
    // ─────────────────────────────────────────────

    uint256 public proposalCount;
    mapping(uint256 => Proposal) private _proposals;

    /// @dev proposalId => voter => hasVoted
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    /// @dev proposalId => voter => voteWeight (for front-end queries)
    mapping(uint256 => mapping(address => uint256)) public voteWeight;

    // ─────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────

    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        string  title,
        uint256 startBlock,
        uint256 endBlock
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        uint8   support,
        uint256 weight
    );
    event ProposalExecuted(uint256 indexed id);
    event ProposalCancelled(uint256 indexed id);

    // ─────────────────────────────────────────────
    //  ERRORS
    // ─────────────────────────────────────────────

    error BelowProposalThreshold();
    error VotingClosed(uint256 proposalId);
    error AlreadyVoted(address voter);
    error InvalidSupport();
    error ProposalNotSucceeded(uint256 proposalId);
    error ExecutionFailed(uint256 actionIndex);
    error Unauthorized();
    error NoActions();

    // ─────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────

    constructor(address _governanceToken) {
        require(_governanceToken != address(0), "zero address");
        governanceToken = IERC20(_governanceToken);
    }

    // ─────────────────────────────────────────────
    //  EXTERNAL FUNCTIONS
    // ─────────────────────────────────────────────

    /**
     * @notice Create a new governance proposal.
     * @param  title       Short human-readable title.
     * @param  description Full description or IPFS CID.
     * @param  targets     Contract addresses to call on execution.
     * @param  values      ETH values for each call.
     * @param  calldatas   Encoded function calls.
     * @return id          The new proposal id.
     */
    function propose(
        string calldata   title,
        string calldata   description,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[]   calldata calldatas
    ) external returns (uint256 id) {
        uint256 supply    = governanceToken.totalSupply();
        uint256 threshold = (supply * PROPOSAL_THRESHOLD_BPS) / 10_000;

        if (governanceToken.balanceOf(msg.sender) < threshold)
            revert BelowProposalThreshold();

        if (targets.length == 0) revert NoActions();
        require(
            targets.length == values.length && values.length == calldatas.length,
            "Array length mismatch"
        );

        id = proposalCount++;
        Proposal storage p = _proposals[id];
        p.id          = id;
        p.proposer    = msg.sender;
        p.title       = title;
        p.description = description;
        p.startBlock  = block.number;
        p.endBlock    = block.number + VOTING_PERIOD;

        for (uint256 i = 0; i < targets.length; i++) {
            p.actions.push(ProposalAction({
                target:   targets[i],
                value:    values[i],
                callData: calldatas[i]
            }));
        }

        emit ProposalCreated(id, msg.sender, title, p.startBlock, p.endBlock);
    }

    /**
     * @notice Cast a vote on an active proposal.
     * @param  proposalId The proposal to vote on.
     * @param  support    0 = Against, 1 = For, 2 = Abstain.
     */
    function castVote(uint256 proposalId, uint8 support) external {
        Proposal storage p = _proposals[proposalId];

        if (block.number > p.endBlock || p.executed || p.cancelled)
            revert VotingClosed(proposalId);
        if (hasVoted[proposalId][msg.sender])
            revert AlreadyVoted(msg.sender);
        if (support > 2) revert InvalidSupport();

        uint256 weight = governanceToken.balanceOf(msg.sender);
        require(weight > 0, "No voting power");

        hasVoted[proposalId][msg.sender]  = true;
        voteWeight[proposalId][msg.sender] = weight;

        if (support == 0) {
            p.againstVotes += weight;
        } else if (support == 1) {
            p.forVotes     += weight;
        } else {
            p.abstainVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /**
     * @notice Execute a succeeded proposal on-chain.
     * @param  proposalId The proposal to execute.
     */
    function execute(uint256 proposalId) external payable {
        if (state(proposalId) != ProposalState.Succeeded)
            revert ProposalNotSucceeded(proposalId);

        Proposal storage p = _proposals[proposalId];
        p.executed = true;

        ProposalAction[] storage actions = p.actions;
        for (uint256 i = 0; i < actions.length; i++) {
            (bool ok, ) = actions[i].target.call{value: actions[i].value}(
                actions[i].callData
            );
            if (!ok) revert ExecutionFailed(i);
        }

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Proposer may cancel their proposal before it is executed.
     * @param  proposalId The proposal to cancel.
     */
    function cancel(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        if (msg.sender != p.proposer) revert Unauthorized();
        if (p.executed) revert ProposalNotSucceeded(proposalId);

        p.cancelled = true;
        emit ProposalCancelled(proposalId);
    }

    // ─────────────────────────────────────────────
    //  VIEW FUNCTIONS
    // ─────────────────────────────────────────────

    /**
     * @notice Returns the current state of a proposal.
     */
    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage p = _proposals[proposalId];

        if (p.cancelled)  return ProposalState.Cancelled;
        if (p.executed)   return ProposalState.Executed;

        if (block.number <= p.endBlock) return ProposalState.Active;

        uint256 supply  = governanceToken.totalSupply();
        uint256 quorum  = (supply * QUORUM_BPS) / 10_000;
        uint256 totalVoted = p.forVotes + p.againstVotes + p.abstainVotes;

        if (totalVoted < quorum)         return ProposalState.Defeated;
        if (p.forVotes <= p.againstVotes) return ProposalState.Defeated;

        return ProposalState.Succeeded;
    }

    /// @notice Returns the full proposal data.
    function getProposal(uint256 proposalId)
        external view
        returns (
            address proposer,
            string  memory title,
            string  memory description,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes,
            uint256 startBlock,
            uint256 endBlock,
            ProposalState proposalState
        )
    {
        Proposal storage p = _proposals[proposalId];
        return (
            p.proposer,
            p.title,
            p.description,
            p.forVotes,
            p.againstVotes,
            p.abstainVotes,
            p.startBlock,
            p.endBlock,
            state(proposalId)
        );
    }

    /// @notice Returns the actions of a proposal.
    function getActions(uint256 proposalId)
        external view
        returns (ProposalAction[] memory)
    {
        return _proposals[proposalId].actions;
    }

    /// @notice Current quorum threshold in tokens.
    function quorumThreshold() external view returns (uint256) {
        return (governanceToken.totalSupply() * QUORUM_BPS) / 10_000;
    }

    // Allow contract to receive ETH for proposal execution
    receive() external payable {}
}
