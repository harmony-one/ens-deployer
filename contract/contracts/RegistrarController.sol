//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import "./TLDBaseRegistrarImplementation.sol";
import {StringUtils} from "@ensdomains/ens-contracts/contracts/ethregistrar/StringUtils.sol";
import {Resolver} from "@ensdomains/ens-contracts/contracts/resolvers/Resolver.sol";
import {ReverseRegistrar} from "@ensdomains/ens-contracts/contracts/registry/ReverseRegistrar.sol";
import {IETHRegistrarController, IPriceOracle} from "@ensdomains/ens-contracts/contracts/ethregistrar/IETHRegistrarController.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {INameWrapper} from "@ensdomains/ens-contracts/contracts/wrapper/INameWrapper.sol";
import {ERC20Recoverable} from "@ensdomains/ens-contracts/contracts/utils/ERC20Recoverable.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @dev A registrar controller for registering and renewing names at fixed cost.
 */
contract RegistrarController is Ownable, IETHRegistrarController, IERC165, ERC20Recoverable {
    error CommitmentTooNew(bytes32 commitment);
    error CommitmentTooOld(bytes32 commitment);
    error NameNotAvailable(string name);
    error DurationTooShort(uint256 duration);
    error ResolverRequiredWhenDataSupplied();
    error UnexpiredCommitmentExists(bytes32 commitment);
    error InsufficientValue();
    error Unauthorised(bytes32 node);
    error MaxCommitmentAgeTooLow();
    error MaxCommitmentAgeTooHigh();

    using StringUtils for *;
    using Address for address;

    uint256 public constant MIN_REGISTRATION_DURATION = 28 days;
    bytes32 public baseNode;
    string public baseExtension;

    uint64 private constant MAX_EXPIRY = type(uint64).max;
    TLDBaseRegistrarImplementation immutable base;
    IPriceOracle public prices;
    uint256 public immutable minCommitmentAge;
    uint256 public immutable maxCommitmentAge;
    ReverseRegistrar public immutable reverseRegistrar;
    INameWrapper public immutable nameWrapper;

    address public immutable revenueAccount;

    mapping(bytes32 => uint256) public commitments;

    event NameRegistered(string name, bytes32 indexed label, address indexed owner, uint256 baseCost, uint256 premium, uint256 expires);
    event NameRenewed(string name, bytes32 indexed label, uint256 cost, uint256 expires);
    event PriceOracleChanged(address oldAddress, address newAddress);

    constructor(
        TLDBaseRegistrarImplementation _base,
        IPriceOracle _prices,
        uint256 _minCommitmentAge,
        uint256 _maxCommitmentAge,
        ReverseRegistrar _reverseRegistrar,
        INameWrapper _nameWrapper,
        bytes32 _baseNode,
        string memory _baseExtension,
        address _revenueAccount
    ) {
        if (_maxCommitmentAge <= _minCommitmentAge) {
            revert MaxCommitmentAgeTooLow();
        }

        if (_maxCommitmentAge > block.timestamp) {
            revert MaxCommitmentAgeTooHigh();
        }

        base = _base;
        prices = _prices;
        minCommitmentAge = _minCommitmentAge;
        maxCommitmentAge = _maxCommitmentAge;
        reverseRegistrar = _reverseRegistrar;
        nameWrapper = _nameWrapper;
        baseNode = _baseNode;
        baseExtension = _baseExtension;
        revenueAccount = _revenueAccount;
    }

    function rentPrice(string memory name, uint256 duration) public view override returns (IPriceOracle.Price memory price) {
        bytes32 label = keccak256(bytes(name));
        price = prices.price(name, base.nameExpires(uint256(label)), duration);
    }

    // @polymorpher: added 2022-02-01, since we are still experimenting with pricing
    function setPrices(IPriceOracle _prices) public onlyOwner {
        address oldAddress = address(prices);
        prices = _prices;
        emit PriceOracleChanged(oldAddress, address(prices));
    }

    function valid(string memory name) public pure returns (bool) {
        return name.strlen() >= 1;
    }

    function available(string memory name) public view override returns (bool) {
        bytes32 label = keccak256(bytes(name));
        return valid(name) && base.available(uint256(label));
    }

    function makeCommitment(
        string memory name,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint32 fuses,
        uint64 wrapperExpiry
    ) public pure override returns (bytes32) {
        bytes32 label = keccak256(bytes(name));
        if (data.length > 0 && resolver == address(0)) {
            revert ResolverRequiredWhenDataSupplied();
        }
        return keccak256(abi.encode(label, owner, duration, resolver, data, secret, reverseRecord, fuses, wrapperExpiry));
    }

    function commit(bytes32 commitment) public override {
        if (commitments[commitment] + maxCommitmentAge >= block.timestamp) {
            revert UnexpiredCommitmentExists(commitment);
        }
        commitments[commitment] = block.timestamp;
    }

    function register(
        string calldata name,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint32 fuses,
        uint64 wrapperExpiry
    ) public payable override {
        IPriceOracle.Price memory price = rentPrice(name, duration);
        if (msg.value < price.base + price.premium) {
            revert InsufficientValue();
        }

        _consumeCommitment(name, duration, makeCommitment(name, owner, duration, secret, resolver, data, reverseRecord, fuses, wrapperExpiry));

        uint256 expires = nameWrapper.registerAndWrapETH2LD(name, owner, duration, resolver, fuses, wrapperExpiry);

        if (data.length > 0) {
            _setRecords(resolver, keccak256(bytes(name)), data);
        }

        if (reverseRecord) {
            _setReverseRecord(name, resolver, owner);
        }

        emit NameRegistered(name, keccak256(bytes(name)), owner, price.base, price.premium, expires);

        if (msg.value > (price.base + price.premium)) {
            payable(msg.sender).transfer(msg.value - (price.base + price.premium));
        }
    }

    function renew(string calldata name, uint256 duration) external payable override {
        _renew(name, duration, 0, 0);
    }

    function renewWithFuses(string calldata name, uint256 duration, uint32 fuses, uint64 wrapperExpiry) external payable {
        bytes32 labelhash = keccak256(bytes(name));
        bytes32 nodehash = keccak256(abi.encodePacked(baseNode, labelhash));
        if (!nameWrapper.isTokenOwnerOrApproved(nodehash, msg.sender)) {
            revert Unauthorised(nodehash);
        }
        _renew(name, duration, fuses, wrapperExpiry);
    }

    function _renew(string calldata name, uint256 duration, uint32 fuses, uint64 wrapperExpiry) internal {
        bytes32 labelhash = keccak256(bytes(name));
        uint256 tokenId = uint256(labelhash);
        IPriceOracle.Price memory price = rentPrice(name, duration);
        if (msg.value < price.base + price.premium) {
            revert InsufficientValue();
        }
        uint256 expires;
        expires = nameWrapper.renew(tokenId, duration, fuses, wrapperExpiry);

//        if (msg.value > price.base + price.premium) {
//            payable(msg.sender).transfer(msg.value - price.base - price.premium);
//        }

        emit NameRenewed(name, labelhash, msg.value, expires);
    }

    function withdraw() public {
        require(msg.sender == owner() || msg.sender == revenueAccount, "RC: must be owner or revenue account");
        (bool success,) = revenueAccount.call{value : address(this).balance}("");
        require(success, "RC: failed to withdraw");
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(IERC165).interfaceId || interfaceID == type(IETHRegistrarController).interfaceId;
    }

    /* Internal functions */

    function _consumeCommitment(string memory name, uint256 duration, bytes32 commitment) internal {
        // Require an old enough commitment.
        if (commitments[commitment] + minCommitmentAge > block.timestamp) {
            revert CommitmentTooNew(commitment);
        }

        // If the commitment is too old, or the name is registered, stop
        if (commitments[commitment] + maxCommitmentAge <= block.timestamp) {
            revert CommitmentTooOld(commitment);
        }
        if (!available(name)) {
            revert NameNotAvailable(name);
        }

        delete (commitments[commitment]);

        if (duration < MIN_REGISTRATION_DURATION) {
            revert DurationTooShort(duration);
        }
    }

    function _setRecords(address resolverAddress, bytes32 label, bytes[] calldata data) internal {
        // use hardcoded .eth namehash
        bytes32 nodehash = keccak256(abi.encodePacked(baseNode, label));
        Resolver resolver = Resolver(resolverAddress);
        resolver.multicallWithNodeCheck(nodehash, data);
    }

    function _setReverseRecord(string memory name, address resolver, address owner) internal {
        reverseRegistrar.setNameForAddr(owner, owner, resolver, string.concat(name, ".", baseExtension));
    }
}
