// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*───────────  OpenZeppelin v5.3 Upgradeables  ──────────*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/*───────────────────────  Contract  ───────────────────────*/
contract BountyManagerPure is Initializable, ReentrancyGuardUpgradeable, ContextUpgradeable {
    using SafeERC20 for IERC20;

    /*─────────────── Custom Errors ───────────────*/
    error ZeroAddress();
    error InvalidString();
    error InvalidPayout();
    error UnknownBounty();
    error AlreadyClaimed();
    error AlreadySubmitted();
    error AlreadyCompleted();
    error NotClaimer();
    error NotCreator();
    error InvalidRecipient();

    /*─────────────── Constants ──────────────────*/
    uint256 public constant MAX_PAYOUT = 1e24; // 1,000,000 tokens (18 dec)
    bytes4 public constant MODULE_ID = 0x42594e33; // "BN3"

    /*─────────────── Data Types ─────────────────*/
    enum Status {
        UNCLAIMED,
        CLAIMED,
        SUBMITTED,
        COMPLETED,
        CANCELLED
    }

    struct Bounty {
        uint248 payout;
        Status status;
        address claimer;
        address creator;
        IERC20 token;
        string ipfsHash;
    }

    /*─────────────── Storage ─────────────────────*/
    mapping(uint256 => Bounty) private _bounties;
    uint256 public nextBountyId;

    /*─────────────── Events ─────────────────────*/
    event BountyCreated(
        uint256 indexed id,
        address indexed token,
        uint256 payout,
        string ipfsHash,
        address indexed creator
    );
    event BountyUpdated(uint256 indexed id, uint256 payout, string ipfsHash);
    event BountyClaimed(uint256 indexed id, address indexed claimer);
    event BountyAssigned(uint256 indexed id, address indexed assignee, address indexed assigner);
    event BountySubmitted(uint256 indexed id, string ipfsHash);
    event BountyCompleted(uint256 indexed id, address indexed recipient, address indexed completer);
    event BountyCancelled(uint256 indexed id, address indexed canceller);

    /*──────────────── Initialiser ───────────────*/
    function initialize() external initializer {
        __ReentrancyGuard_init();
        __Context_init();
    }

    /*─────────────────── Bounty Logic ──────────────────*/
    function createBounty(IERC20 token, uint256 payout, string calldata ipfsHash) external {
        if (address(token) == address(0)) revert ZeroAddress();
        if (payout == 0 || payout > MAX_PAYOUT) revert InvalidPayout();
        if (bytes(ipfsHash).length == 0) revert InvalidString();

        // transfer funds into escrow
        token.safeTransferFrom(_msgSender(), address(this), payout);

        uint256 id = nextBountyId++;
        _bounties[id] = Bounty({
            payout: SafeCast.toUint248(payout),
            status: Status.UNCLAIMED,
            claimer: address(0),
            creator: _msgSender(),
            token: token,
            ipfsHash: ipfsHash
        });

        emit BountyCreated(id, address(token), payout, ipfsHash, _msgSender());
    }

    function updateBounty(uint256 id, uint256 newPayout, string calldata newIpfsHash) external {
        Bounty storage b = _bounty(id);
        if (b.creator != _msgSender()) revert NotCreator();

        if (b.status == Status.CLAIMED || b.status == Status.SUBMITTED) {
            if (bytes(newIpfsHash).length == 0) revert InvalidString();
            b.ipfsHash = newIpfsHash;
        } else if (b.status == Status.UNCLAIMED) {
            if (newPayout == 0 || newPayout > MAX_PAYOUT) revert InvalidPayout();

            // adjust escrow if payout changed
            if (newPayout > b.payout) {
                uint256 diff = newPayout - b.payout;
                b.token.safeTransferFrom(_msgSender(), address(this), diff);
            } else if (newPayout < b.payout) {
                uint256 diff = b.payout - newPayout;
                b.token.safeTransfer(b.creator, diff);
            }

            b.payout = SafeCast.toUint248(newPayout);
            if (bytes(newIpfsHash).length != 0) b.ipfsHash = newIpfsHash;
        } else {
            revert AlreadyCompleted();
        }

        emit BountyUpdated(id, newPayout, newIpfsHash);
    }

    function claimBounty(uint256 id) external {
        Bounty storage b = _bounty(id);
        if (b.status != Status.UNCLAIMED) revert AlreadyClaimed();

        b.status = Status.CLAIMED;
        b.claimer = _msgSender();
        emit BountyClaimed(id, _msgSender());
    }

    function assignBounty(uint256 id, address assignee) external {
        if (assignee == address(0)) revert ZeroAddress();

        Bounty storage b = _bounty(id);
        if (b.status != Status.UNCLAIMED) revert AlreadyClaimed();
        if (b.creator != _msgSender()) revert NotCreator();

        b.status = Status.CLAIMED;
        b.claimer = assignee;
        emit BountyAssigned(id, assignee, _msgSender());
    }

    function submitBounty(uint256 id, string calldata ipfsHash) external {
        Bounty storage b = _bounty(id);
        if (b.status != Status.CLAIMED) revert AlreadySubmitted();
        if (b.claimer != _msgSender()) revert NotClaimer();
        if (bytes(ipfsHash).length == 0) revert InvalidString();

        b.status = Status.SUBMITTED;
        b.ipfsHash = ipfsHash;
        emit BountySubmitted(id, ipfsHash);
    }

    function completeBounty(uint256 id, address recipient) external nonReentrant {
        Bounty storage b = _bounty(id);
        if (b.status != Status.SUBMITTED) revert AlreadyCompleted();
        if (b.creator != _msgSender()) revert NotCreator();
        if (recipient == address(0) || recipient == b.creator) revert InvalidRecipient();

        b.token.safeTransfer(recipient, b.payout);
        b.status = Status.COMPLETED;
        emit BountyCompleted(id, recipient, _msgSender());
    }

    function cancelBounty(uint256 id) external {
        Bounty storage b = _bounty(id);
        if (b.status != Status.UNCLAIMED) revert AlreadyClaimed();
        if (b.creator != _msgSender()) revert NotCreator();

        b.status = Status.CANCELLED;
        b.token.safeTransfer(b.creator, b.payout);
        emit BountyCancelled(id, _msgSender());
    }

    /*──────────── View Helpers ───────────*/
    function getBounty(uint256 id)
        external
        view
        returns (
            uint256 payout,
            Status status,
            address claimer,
            address creator,
            IERC20 token,
            string memory ipfs
        )
    {
        Bounty storage b = _bounty(id);
        return (b.payout, b.status, b.claimer, b.creator, b.token, b.ipfsHash);
    }

    /*──────────── Internal Utils ───────────*/
    function _bounty(uint256 id) internal view returns (Bounty storage b) {
        if (id >= nextBountyId) revert UnknownBounty();
        b = _bounties[id];
    }

    /*──────────── Version & Gap ───────────*/
    function version() external pure returns (string memory) {
        return "v2";
    }

    uint256[100] private __gap;
}
