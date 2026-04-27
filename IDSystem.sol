// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract IDSystem is AccessControl {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    constructor(address admin, address issuer) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ISSUER_ROLE, issuer);
    }
    enum Status {None, Active, Suspended, Revoked }
    struct identity {
        bytes32 citizenHash;
        bytes32 profileHash;
        address wallet;
        uint64 issueAt;
        uint64 updateAt;
        Status status;
    }
    mapping (bytes32 => identity) private _identities;
    mapping (address => bytes32) private walletLinkedToCitizen;
    mapping (address => mapping(bytes32 => bool)) private verificationConsent;

    event CitizenRegistered(bytes32 indexed citizenHash, address indexed wallet, bytes32 profileHash, uint64 issueAt);
    event UpdateCitizen(bytes32 indexed citizenHash, bytes32 oldProfileHash, bytes32 newProfileHash, uint64 updateAt);
    event WalletChanged(bytes32 indexed citizenHash, address oldWallet, address newWallet);
    event ConsentSet(bytes32 indexed citizenHash, address indexed verifier, bool consent);

    modifier onlyExistingCitizen(bytes32 citizenHash) {
        require(_identities[citizenHash].status != Status.None, "Citizen does not exist");
        _;
    }
    modifier onlyOwnerorAdmin(bytes32 citizenHash) {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || _identities[citizenHash].wallet == msg.sender, "Not authorized");
        _;
    }
    function registerCitizen(bytes32 citizenHash, address wallet, bytes32 profileHash) public onlyRole(ISSUER_ROLE) {
       require (citizenHash != bytes32(0), "Invalid citizen hash");
       require (wallet != address(0), "Invalid wallet address");
       require (profileHash != bytes32(0), "Invalid profile hash");
       require (_identities[citizenHash].status == Status.None, "Citizen already exists");
       require (walletLinkedToCitizen[wallet] == bytes32(0), "Wallet already associated with another citizen");

       uint64 nowAt = uint64(block.timestamp);

       _identities[citizenHash] = identity({
           citizenHash: citizenHash,
           profileHash: profileHash,
           wallet: wallet,
           issueAt: nowAt,
           updateAt: nowAt,
           status: Status.Active
       });

       walletLinkedToCitizen[wallet] = citizenHash;

       emit CitizenRegistered(citizenHash, wallet, profileHash, nowAt);
    }

    function updateCitizen(bytes32 citizenHash, bytes32 newProfileHash) public 
        onlyExistingCitizen(citizenHash) onlyOwnerorAdmin(citizenHash) 
    {
        require(newProfileHash != bytes32(0), "Invalid profile hash");

        uint64 nowAt = uint64(block.timestamp);
        bytes32 oldProfileHash = _identities[citizenHash].profileHash;

        _identities[citizenHash].profileHash = newProfileHash;
        _identities[citizenHash].updateAt = nowAt;

        emit UpdateCitizen(citizenHash, oldProfileHash, newProfileHash, nowAt);
    }

    function changeWallet(bytes32 citizenHash, address newWallet) public 
        onlyExistingCitizen(citizenHash) onlyOwnerorAdmin(citizenHash) 
    {
        require(newWallet != address(0), "Invalid wallet address");
        require(walletLinkedToCitizen[newWallet] == bytes32(0), "Wallet already associated with another citizen");
        address oldWallet = _identities[citizenHash].wallet;
        delete walletLinkedToCitizen[oldWallet];
        walletLinkedToCitizen[newWallet] = citizenHash;
        _identities[citizenHash].wallet = newWallet;
        emit WalletChanged(citizenHash, oldWallet, newWallet);
    }

    function suspendCitizen(bytes32 citizenHash) public 
        onlyExistingCitizen(citizenHash) onlyRole(DEFAULT_ADMIN_ROLE) 
    {   
        identity storage rec = _identities[citizenHash];
        require(rec.status == Status.Active, "Citizen must be active to suspend");
        rec.status = Status.Suspended;
    }

    function reactiveCitizen(bytes32 citizenHash) public 
        onlyExistingCitizen(citizenHash) onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        identity storage rec = _identities[citizenHash];
        require(rec.status == Status.Suspended, "Citizen must be suspended to reactivate");
        rec.status = Status.Active;
    }

    function revokeCitizen(bytes32 citizenHash) public 
        onlyExistingCitizen(citizenHash) onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        identity storage rec = _identities[citizenHash];
        require(rec.status != Status.Revoked, "Citizen already revoked");
        rec.status = Status.Revoked;
    }

    function setConsent(bytes32 citizenHash, address verifier, bool consent) public 
        onlyExistingCitizen(citizenHash) onlyOwnerorAdmin(citizenHash) 
    {
        require(verifier != address(0), "Invalid verifier address");
        verificationConsent[verifier][citizenHash] = consent;
        emit ConsentSet(citizenHash, verifier, consent);
    }

    function checkVerifyConsent(bytes32 citizenHash, bytes32 claimProfileHash) public view returns (bool) {
        identity memory rec = _identities[citizenHash];
        require(rec.status == Status.Active, "Citizen is not active");
        require(rec.profileHash == claimProfileHash, "Profile hash does not match");
        return verificationConsent[msg.sender][citizenHash];
    }

    function getIdentity(bytes32 citizenHash) public view returns (identity memory) {
        return _identities[citizenHash];
    }

    function myCitizenHash() public view returns (bytes32) {
        return walletLinkedToCitizen[msg.sender];
    }
}