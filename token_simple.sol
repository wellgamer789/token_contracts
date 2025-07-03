/*
Name (symbol) - t.me/templatename
*/

// SPDX-License-Identifier: none
pragma solidity 0.8.23;

contract TEST {
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error InsufficientBalance();
    error InsufficientAllowance();

    string constant public name = "TEST";
    string constant public symbol = "TEST";

    uint8 constant public decimals = 9;
    uint256 constant public totalSupply = 100_000_000 * (10 ** decimals);

    mapping (address => uint256) public balanceOf;
    mapping (address => mapping(address => uint256)) public allowance;

    constructor() {
        unchecked {
            balanceOf[msg.sender] = totalSupply;
            emit Transfer(address(0), msg.sender, totalSupply);
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////// TRANSFER //////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        return _basicTransfer(msg.sender, recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[sender][msg.sender];

        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();

            unchecked {
                allowance[sender][msg.sender] = allowed - amount;
            }
        }

        return _basicTransfer(sender, recipient, amount);
    }

    function _basicTransfer(address sender, address recipient, uint256 amount) internal returns (bool) {
        if (balanceOf[sender] < amount) revert InsufficientBalance();

        unchecked {
            balanceOf[sender] -= amount;
            balanceOf[recipient] += amount;
            emit Transfer(sender, recipient, amount);
        }
        
        return true;
    }
}