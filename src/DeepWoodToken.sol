// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DeepWoodToken
 * @notice Minimal ERC-20 for $DEEPWOOD. Nothing here is game-critical: the
 *         economy in DeepWood.sol settles in ETH until an operator deliberately
 *         turns the token rail on. This contract only has to be correct and
 *         boring.
 *
 * Design notes:
 *  - Fixed supply. No mint-after-launch, so a deployer cannot quietly print
 *    supply. The owner may mint ONLY up to the cap, and only before the
 *    cap is sealed with `seal()`. Sealing is one-way and irreversible.
 *  - The game contract never pulls tokens from a player. Redemption pays out
 *    to the player; it never takes. So there is no allowance dance here.
 */
contract DeepWoodToken {
    // ---- ERC-20 -----------------------------------------------------------

    string public constant name = "DeepWood";
    string public constant symbol = "DEEPWOOD";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---- supply policy ----------------------------------------------------

    address public OWNER;

    /// @notice Hard ceiling. totalSupply can never exceed this.
    uint256 public immutable CAP;

    /// @notice Once true, mint() is dead forever. Lets the owner commit to a
    ///         final number, and lets a contract integration rely on it.
    bool public mintClosed;

    event Sealed(uint256 finalSupply);

    error NotOwner();
    error MintClosed_();
    error CapExceeded();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    constructor(address owner, uint256 cap) {
        if (owner == address(0)) revert ZeroAddress();
        OWNER = owner;
        CAP = cap;
    }

    // ---- owner actions ----------------------------------------------------

    /// @notice Mint to an address, up to CAP. Reverts once sealed.
    function mint(address to, uint256 amount) external onlyOwner {
        if (mintClosed) revert MintClosed_();
        if (to == address(0)) revert ZeroAddress();
        uint256 next = totalSupply + amount;
        if (next > CAP) revert CapExceeded();
        totalSupply = next;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Permanently close minting. One-way.
    function seal() external onlyOwner {
        if (mintClosed) revert MintClosed_();
        mintClosed = true;
        emit Sealed(totalSupply);
    }

    /// @notice Hand the remaining mint rights to someone else. The new owner
    ///         controls minting AND mintClosed.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        OWNER = newOwner;
    }

    // ---- ERC-20 core ------------------------------------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance();
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
