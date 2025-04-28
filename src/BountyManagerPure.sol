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
    error EmptyDescription();
    error InvalidPayout();
    error UnknownBounty();
    error NotCreator();
    error InvalidStateTransition();
    error InvalidRecipient();

    /*─────────────── Constants ──────────────────*/
    uint256 public constant MAX_PAYOUT = 1e24; // 1,000,000 tokens (18 dec)
    bytes4 public constant MODULE_ID = 0x42594e33; // "BN3"

    /*─────────────── Data Types ─────────────────*/
    enum Status {
        ACTIVE,
        COMPLETED,
        CANCELLED
    }

    struct Bounty {
        uint248 payout;
        Status status;
        address creator;
        IERC20 token;
        string description;
    }

    /*─────────────── Storage ─────────────────────*/
    mapping(uint256 => Bounty) private _bounties;
    uint256 public nextBountyId;

    /*─────────────── Events ─────────────────────*/
    event BountyCreated(
        uint256 indexed id,
        address indexed token,
        uint256 payout,
        string description,
        address indexed creator
    );
    event BountyUpdated(uint256 indexed id, uint256 payout, string description);
    event BountyCompleted(uint256 indexed id, address indexed recipient, address indexed completer);
    event BountyCancelled(uint256 indexed id, address indexed canceller);

    /*──────────────── Initialiser ───────────────*/
    function initialize() external initializer {
        __ReentrancyGuard_init();
        __Context_init();
    }

    /*─────────────────── Bounty Logic ──────────────────*/
    function createBounty(IERC20 token, uint256 payout, string calldata description) external {
        if (address(token) == address(0)) revert ZeroAddress();
        if (payout == 0 || payout > MAX_PAYOUT) revert InvalidPayout();
        if (bytes(description).length == 0) revert EmptyDescription();

        // transfer funds into escrow
        token.safeTransferFrom(_msgSender(), address(this), payout);

        uint256 id = nextBountyId++;
        _bounties[id] = Bounty({
            payout: SafeCast.toUint248(payout),
            status: Status.ACTIVE,
            creator: _msgSender(),
            token: token,
            description: description
        });

        emit BountyCreated(id, address(token), payout, description, _msgSender());
    }

    function updateBounty(uint256 id, uint256 newPayout, string calldata newDescription) external {
        Bounty storage b = _bounty(id);
        if (b.creator != _msgSender()) revert NotCreator();
        if (b.status != Status.ACTIVE) revert InvalidStateTransition();

        if (newPayout == 0 || newPayout > MAX_PAYOUT) revert InvalidPayout();
        if (bytes(newDescription).length == 0) revert EmptyDescription();

        // adjust escrow if payout changed
        if (newPayout > b.payout) {
            uint256 diff = newPayout - b.payout;
            b.token.safeTransferFrom(_msgSender(), address(this), diff);
        } else if (newPayout < b.payout) {
            revert InvalidPayout();
        }

        b.payout = SafeCast.toUint248(newPayout);
        b.description = newDescription;

        emit BountyUpdated(id, newPayout, newDescription);
    }

    function completeBounty(uint256 id, address recipient) external nonReentrant {
        Bounty storage b = _bounty(id);
        if (b.status != Status.ACTIVE) revert InvalidStateTransition();
        if (b.creator != _msgSender()) revert NotCreator();
        if (recipient == address(0) || recipient == b.creator) revert InvalidRecipient();

        b.token.safeTransfer(recipient, b.payout);
        b.status = Status.COMPLETED;
        emit BountyCompleted(id, recipient, _msgSender());
    }

    function cancelBounty(uint256 id) external {
        Bounty storage b = _bounty(id);
        if (b.status != Status.ACTIVE) revert InvalidStateTransition();
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
            address creator,
            IERC20 token,
            string memory description
        )
    {
        Bounty storage b = _bounty(id);
        return (b.payout, b.status, b.creator, b.token, b.description);
    }

    /*──────────── Internal Utils ───────────*/
    function _bounty(uint256 id) internal view returns (Bounty storage b) {
        if (id >= nextBountyId) revert UnknownBounty();
        b = _bounties[id];
    }

    /*──────────── Version & Gap ───────────*/
    function version() external pure returns (string memory) {
        return "v1";
    }

    uint256[100] private __gap;
}
