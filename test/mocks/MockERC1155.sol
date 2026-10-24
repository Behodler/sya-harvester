// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";

/// @notice Claim-NFT stand-in modelling NFTMinterV2 for unit tests.
/// @dev Plain transferable ERC1155 with supply tracking (`ERC1155Supply`, as live): transfers need the
///      holder's approval as usual. `burn` mirrors NFTMinterV2's authorized-burner burn: an authorized
///      burner (SYA) burns from `from` with no approval from `from`.
contract MockERC1155 is ERC1155Supply {
    error NotAuthorizedBurner(address caller);

    mapping(address => bool) public authorizedBurners;

    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function setAuthorizedBurner(address burner, bool authorized) external {
        authorizedBurners[burner] = authorized;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        if (!authorizedBurners[msg.sender]) revert NotAuthorizedBurner(msg.sender);
        _burn(from, id, amount);
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155Supply)
    {
        super._update(from, to, ids, values);
    }
}
