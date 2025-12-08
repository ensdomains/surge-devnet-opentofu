// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMessageInvocable {
    function onMessageInvocation(bytes calldata _data) external payable;
}

contract ValueStore is IMessageInvocable {
    uint256 public value;
    address public bridge;

    event ValueChanged(uint256 newValue, address caller);

    constructor(address _bridge) {
        bridge = _bridge;
    }

    function onMessageInvocation(bytes calldata _data) external payable {
        require(msg.sender == bridge, "Only bridge can call");

        (bool success, bytes memory returnData) = address(this).call(_data);

        if (!success) {
            if (returnData.length > 0) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            } else {
                revert("Function call failed");
            }
        }
    }

    function setValue(uint256 _value) external {
        value = _value;
        emit ValueChanged(_value, msg.sender);
    }
}
