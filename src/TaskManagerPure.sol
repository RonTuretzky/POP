// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*───────────  OpenZeppelin v5.3 Upgradeables  ──────────*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";

/*────────── External Interfaces ──────────*/
interface IParticipationToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

/*───────────────────────  Contract  ───────────────────────*/
contract TaskManagerPure is Initializable, ReentrancyGuardUpgradeable, ContextUpgradeable {
    /*─────────────── Custom Errors ───────────────*/
    error ZeroAddress();
    error InvalidString();
    error InvalidPayout();
    error UnknownTask();
    error InvalidStateTransition();
    error NotClaimer();

    /*─────────────── Constants ──────────────────*/
    uint256 public constant MAX_PAYOUT = 1e24; // 1,000,000 tokens (18 dec)
    bytes4 public constant MODULE_ID = 0x54534b33; // "TSK3"

    /*─────────────── Data Types ─────────────────*/
    enum Status {
        UNCLAIMED,
        CLAIMED,
        SUBMITTED,
        COMPLETED,
        CANCELLED
    }

    struct Task {
        uint248 payout;
        Status status;
        address claimer;
        string ipfsHash;
    }

    /*─────────────── Storage ─────────────────────*/
    mapping(uint256 => Task) private _tasks;
    IParticipationToken public token;
    uint256 public nextTaskId;

    /*─────────────── Events ─────────────────────*/
    // ── Task
    event TaskCreated(uint256 indexed id, uint256 payout, string ipfsHash);
    event TaskUpdated(uint256 indexed id, uint256 payout, string ipfsHash);
    event TaskClaimed(uint256 indexed id, address indexed claimer);
    event TaskAssigned(uint256 indexed id, address indexed assignee, address indexed assigner);
    event TaskSubmitted(uint256 indexed id, string ipfsHash);
    event TaskCompleted(uint256 indexed id, address indexed completer);
    event TaskCancelled(uint256 indexed id, address indexed canceller);

    /*──────────────── Initialiser ───────────────*/
    function initialize(address tokenAddress) external initializer {
        if (tokenAddress == address(0)) {
            revert ZeroAddress();
        }
        __ReentrancyGuard_init();
        __Context_init();

        token = IParticipationToken(tokenAddress);
    }

    /*─────────────────── Task Logic ──────────────────*/
    function createTask(uint256 payout, string calldata ipfsHash) external {
        if (payout == 0 || payout > MAX_PAYOUT) revert InvalidPayout();
        if (bytes(ipfsHash).length == 0) revert InvalidString();

        uint256 id = nextTaskId++;
        _tasks[id] = Task({
            payout: uint248(payout),
            status: Status.UNCLAIMED,
            claimer: address(0),
            ipfsHash: ipfsHash
        });

        emit TaskCreated(id, payout, ipfsHash);
    }

    function updateTask(uint256 id, uint256 newPayout, string calldata newIpfsHash) external {
        Task storage t = _task(id);

        if (t.status == Status.CLAIMED || t.status == Status.SUBMITTED) {
            if (bytes(newIpfsHash).length == 0) revert InvalidString();
            t.ipfsHash = newIpfsHash;
        } else if (t.status == Status.UNCLAIMED) {
            if (newPayout == 0 || newPayout > MAX_PAYOUT) revert InvalidPayout();
            t.payout = uint248(newPayout);
            if (bytes(newIpfsHash).length != 0) t.ipfsHash = newIpfsHash;
        } else {
            revert InvalidStateTransition();
        }

        emit TaskUpdated(id, newPayout, newIpfsHash);
    }

    function claimTask(uint256 id) external {
        Task storage t = _task(id);
        if (t.status != Status.UNCLAIMED) revert InvalidStateTransition();

        t.status = Status.CLAIMED;
        t.claimer = _msgSender();
        emit TaskClaimed(id, _msgSender());
    }

    function assignTask(uint256 id, address assignee) external {
        if (assignee == address(0)) revert ZeroAddress();

        Task storage t = _task(id);
        if (t.status != Status.UNCLAIMED) revert InvalidStateTransition();

        t.status = Status.CLAIMED;
        t.claimer = assignee;
        emit TaskAssigned(id, assignee, _msgSender());
    }

    function submitTask(uint256 id, string calldata ipfsHash) external {
        Task storage t = _task(id);
        if (t.status != Status.CLAIMED) revert InvalidStateTransition();
        if (t.claimer != _msgSender()) revert NotClaimer();
        if (bytes(ipfsHash).length == 0) revert InvalidString();

        t.status = Status.SUBMITTED;
        t.ipfsHash = ipfsHash;
        emit TaskSubmitted(id, ipfsHash);
    }

    function completeTask(uint256 id) external nonReentrant {
        Task storage t = _task(id);
        if (t.status != Status.SUBMITTED) revert InvalidStateTransition();

        token.mint(t.claimer, t.payout);
        t.status = Status.COMPLETED;
        emit TaskCompleted(id, _msgSender());
    }

    function cancelTask(uint256 id) external {
        Task storage t = _task(id);
        if (t.status != Status.UNCLAIMED) revert InvalidStateTransition();

        t.status = Status.CANCELLED;
        emit TaskCancelled(id, _msgSender());
    }

    /*──────────── View Helpers ───────────*/
    function getTask(uint256 id)
        external
        view
        returns (uint256 payout, Status status, address claimer, string memory ipfs)
    {
        Task storage t = _task(id);
        return (t.payout, t.status, t.claimer, t.ipfsHash);
    }

    /*──────────── Internal Utils ───────────*/
    function _task(uint256 id) internal view returns (Task storage t) {
        if (id >= nextTaskId) revert UnknownTask();
        t = _tasks[id];
    }

    /*──────────── Version & Gap ───────────*/
    function version() external pure returns (string memory) {
        return "v1";
    }

    uint256[100] private __gap;
} 