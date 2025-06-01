// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {StringUtils} from "./libraries/StringUtils.sol";
import {Base64} from "./libraries/Base64.sol";

/*                                   
     _____           _       _    _____     _   
    |  |  |___ ___ _| |___ _| |  |  |  |_ _| |_ 
    |     | . | . | . | -_| . |  |     | | | . |
    |__|__|___|___|___|___|___|  |__|__|___|___|
                                                                  
*/


/**
 * @title ANS: Abstract Name Service
 * @dev This contract implements a domain name service for the Abstract ecosystem
 * with upgradeable proxy pattern, case insensitivity, and additional features.
 */

contract AnsAbstractNameService is 
    Initializable, 
    ERC721URIStorageUpgradeable, 
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using CountersUpgradeable for CountersUpgradeable.Counter;
    
    // Constants
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    // Variables
    IERC721 public nftCollection;
    string public tld;
    CountersUpgradeable.Counter private _tokenIds;
    address public primaryTreasury;   // 90% recipient
    address public secondaryTreasury; // 10% recipient

    // Mappings
    mapping(string => address) public domains;       // normalized name => owner
    mapping(string => string) public records;        // normalized name => record
    mapping(uint => string) public names;            // token ID => normalized name
    mapping(address => string[]) public domainsByOwner;  // owner => array of domains owned
    mapping(string => address) public addressByRecord;   // address string => domain owner (for reverse lookup)

    // Coupon system
    struct Coupon {
        uint256 discountPercentage;  // Discount percentage (1-100)
        uint256 maxUses;             // Maximum number of times this coupon can be used
        uint256 usedCount;           // Number of times this coupon has been used
        bool isActive;               // Whether this coupon is active
        uint256 validUntil;          // Timestamp until which the coupon is valid
    }
    mapping(string => Coupon) public coupons;        // coupon code => Coupon struct

    // Migration support
    address public oldContractAddress;
    
    // Parts of the SVG for NFT images
    string internal _svgPartOne;
    string internal _svgPartTwo;
    string internal _backgroundImageUrl;
    
    // Collection-level metadata
    string internal _contractURI;

    //ERRORS
    error Unauthorized();
    error AlreadyRegistered();
    error InvalidName(string name);
    error CouponExpired();
    error CouponInactive();
    error CouponMaxUsesReached();
    error MigrationFailed();
    error InvalidRecord();
    error AddressAlreadyInUse(string currentDomain);
    
    //EVENTS
    event RecordSet(string indexed name, string record, address indexed setter);
    event DomainTransferred(string indexed name, address indexed from, address indexed to);
    event CouponCreated(string couponCode, uint256 discountPercentage, uint256 maxUses, uint256 validUntil);
    event CouponUsed(string couponCode, address user, string domainName, uint256 discountedPrice);
    event DomainMigrated(string name, address owner, string newName);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initializes the contract
     * @param _tld The top level domain (e.g. "abs")
     * @param _nftCollection The address of the NFT collection used for discounts
     * @param _primaryTreasury The address where 90% of registration fees will be sent
     * @param _secondaryTreasury The address where 10% of registration fees will be sent
     * @param _oldContract The address of the old ANS contract for migrations
     */
    function initialize(
        string memory _tld,
        address _nftCollection,
        address _primaryTreasury,
        address _secondaryTreasury,
        address _oldContract
    ) public initializer {
        __ERC721_init("ANS: Abstract Name Service", "ANS");
        __ERC721URIStorage_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        
        tld = _tld;
        nftCollection = IERC721(_nftCollection);
        primaryTreasury = _primaryTreasury;
        secondaryTreasury = _secondaryTreasury;
        oldContractAddress = _oldContract;
        
        // Background image URL for NFTs
        _backgroundImageUrl = "https://raw.githubusercontent.com/0xShroomy/ANS-Abstract-Name-Service/b44204dd543cfee832b70122462583e176ab6cc8/ANS-AbstractNameService.png";
        
        // Set collection-level metadata with the avatar
        string memory avatarUrl = "https://raw.githubusercontent.com/0xShroomy/ANS-Abstract-Name-Service/0d08cb168f59befba8d0adf02995d531039aca7a/ANS-AbstractNameService-Avatar.png";
        string memory collectionJson = string(abi.encodePacked(
            '{',
            '"name": "ANS: Abstract Name Service",',
            '"description": "Abstract Name Service (ANS) domains are secure domain names for the Abstract blockchain ecosystem. ANS domains provide a way for users to map human readable names to blockchain and non-blockchain resources.",',
            '"image": "', avatarUrl, '",',
            '"external_link": "",',
            '"seller_fee_basis_points": 0,',
            '"fee_recipient": ""',
            '}'
        ));
        _contractURI = string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(collectionJson))));
        
        // Set default NFT styling
        _svgPartOne = string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 1000 1000">',
            '<defs>',
            '<style>',
            '.domain-name{font-family:Arial,sans-serif;font-weight:normal;fill:#ffffff;text-anchor:start;}',
            '.tld-text{font-family:Arial,sans-serif;font-weight:normal;fill:#a8aba9;text-anchor:start;}',
            '</style>',
            '</defs>',
            '<image href="', _backgroundImageUrl, '" width="1000" height="1000"/>',
            '<text x="50" y="900" class="domain-name" font-size="38">'
        ));
            
        _svgPartTwo = string(abi.encodePacked(
            '</text>',
            '<text x="50" y="950" class="tld-text" font-size="38">.abs</text>',
            '</svg>'
        ));
    }

    /**
     * @dev Required by the UUPSUpgradeable module
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    /**
     * @dev Normalizes a name by converting to lowercase
     * This ensures "BOB", "bob", and "BoB" are all treated as the same name
     */
    function _normalizeName(string memory name) internal pure returns (string memory) {
        bytes memory nameBytes = bytes(name);
        bytes memory result = new bytes(nameBytes.length);
        
        for (uint i = 0; i < nameBytes.length; i++) {
            // Convert uppercase to lowercase
            if (nameBytes[i] >= 0x41 && nameBytes[i] <= 0x5A) {
                // ASCII A-Z (65-90) to a-z (97-122)
                result[i] = bytes1(uint8(nameBytes[i]) + 32);
            } else {
                result[i] = nameBytes[i];
            }
        }
        
        return string(result);
    }
    
    /**
     * @dev Validates if a name meets the requirements
     * Only ASCII alphanumeric characters are allowed (no Unicode or emojis)
     */
    function valid(string calldata name) public pure returns (bool) {
        bytes memory nameBytes = bytes(name);
        if (nameBytes.length < 1) return false;
        
        for (uint i = 0; i < nameBytes.length; i++) {
            bytes1 char = nameBytes[i];
            
            // Only allow a-z, A-Z, 0-9, and hyphen (-)
            bool isLetter = (char >= 0x41 && char <= 0x5A) || (char >= 0x61 && char <= 0x7A); // A-Z or a-z
            bool isNumber = char >= 0x30 && char <= 0x39; // 0-9
            bool isHyphen = char == 0x2D; // -
            
            if (!(isLetter || isNumber || isHyphen)) {
                return false;
            }
        }
        
        return true;
    }
    
    /**
     * @dev Updates domain ownership when an NFT is transferred
     */
    function _updateDomainOwnership(uint256 tokenId, address from, address to) internal {
        string memory name = names[tokenId];
        if (bytes(name).length > 0) {
            // Update domain owner
            domains[name] = to;
            
            // Update domainsByOwner for the from address (remove)
            if (from != address(0)) {
                string[] storage fromDomains = domainsByOwner[from];
                for (uint i = 0; i < fromDomains.length; i++) {
                    if (keccak256(bytes(fromDomains[i])) == keccak256(bytes(name))) {
                        // Swap with the last element and pop
                        fromDomains[i] = fromDomains[fromDomains.length - 1];
                        fromDomains.pop();
                        break;
                    }
                }
            }
            
            // Update domainsByOwner for the to address (add)
            if (to != address(0) && to != DEAD_ADDRESS) {
                domainsByOwner[to].push(name);
            }
            
            emit DomainTransferred(string(bytes(name)), from, to);
        }
    }
    
    /**
     * @dev Override transferFrom to keep domain ownership in sync
     */
    function transferFrom(address from, address to, uint256 tokenId) 
        public 
        virtual 
        override(ERC721Upgradeable) 
    {
        super.transferFrom(from, to, tokenId);
        _updateDomainOwnership(tokenId, from, to);
    }
    
    /**
     * @dev Override safeTransferFrom to keep domain ownership in sync
     */
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) 
        public 
        virtual 
        override(ERC721Upgradeable)
    {
        super.safeTransferFrom(from, to, tokenId, data);
        _updateDomainOwnership(tokenId, from, to);
    }
    
    /**
     * @dev Transfer a domain to another address
     */
    function transferDomain(string calldata name, address to) public {
        string memory normalizedName = _normalizeName(name);
        if (msg.sender != domains[normalizedName]) revert Unauthorized();
        
        // Find the token ID for this name
        uint256 tokenId;
        bool found = false;
        for (uint i = 0; i < _tokenIds.current(); i++) {
            if (keccak256(bytes(names[i])) == keccak256(bytes(normalizedName))) {
                tokenId = i;
                found = true;
                break;
            }
        }
        require(found, "Domain not found");
        
        // Transfer the NFT (this will also update domain ownership through overridden transfer)
        transferFrom(msg.sender, to, tokenId);
    }
    
    /**
     * @dev Calculate the price of a domain based on length
     */
    function price(string memory name) public view returns (uint) {
        uint len = StringUtils.strlen(name);
        require(len > 0, "Invalid name length");
        
        uint basePrice;
        
        if (len == 1) basePrice = 0.1750 ether;       
        else if (len == 2) basePrice = 0.1500 ether; 
        else if (len == 3) basePrice = 0.1250 ether; 
        else if (len == 4) basePrice = 0.0750 ether; 
        else if (len == 5) basePrice = 0.0600 ether; 
        else if (len == 6) basePrice = 0.0500 ether; 
        else if (len == 7) basePrice = 0.0400 ether; 
        else if (len == 8) basePrice = 0.0300 ether;  
        else if (len == 9) basePrice = 0.0200 ether;  
        else if (len == 10) basePrice = 0.0150 ether; 
        else if (len == 11) basePrice = 0.0100 ether; 
        else if (len == 12) basePrice = 0.0075 ether; 
        else if (len == 13) basePrice = 0.0040 ether; 
        else if (len == 14) basePrice = 0.0020 ether; 
        else basePrice = 0.0010 ether;                

        // Apply 50% discount if the sender holds an NFT
        if (nftCollection.balanceOf(msg.sender) > 0) {
            return basePrice / 2;
        }

        return basePrice;
    }
    
    /**
     * @dev Apply a coupon discount to a price
     */
    function applyDiscount(uint256 originalPrice, string memory couponCode) public view returns (uint256) {
        Coupon memory coupon = coupons[couponCode];
        if (!coupon.isActive) revert CouponInactive();
        if (coupon.validUntil < block.timestamp) revert CouponExpired();
        if (coupon.usedCount >= coupon.maxUses) revert CouponMaxUsesReached();
        
        return originalPrice * (100 - coupon.discountPercentage) / 100;
    }
    
    /**
     * @dev Register a new domain name
     */
    function register(string memory name) public payable {
        _registerWithDiscount(name, "");
    }
    
    /**
     * @dev Register a new domain with a discount coupon
     */
    function registerWithCoupon(string memory name, string memory couponCode) public payable {
        _registerWithDiscount(name, couponCode);
    }
    
    /**
     * @dev Internal function to handle domain registration with optional discount
     */
    function _registerWithDiscount(string memory name, string memory couponCode) internal {
        // Normalize the name to lowercase
        string memory normalizedName = _normalizeName(name);
        
        // Check if domain is already registered or name is invalid
        if (domains[normalizedName] != address(0)) revert AlreadyRegistered();
        
        // Manually check validity (instead of calling valid function)
        bytes memory nameBytes = bytes(normalizedName);
        if (nameBytes.length < 1) revert InvalidName(normalizedName);
        
        // Check each character is valid ASCII alphanumeric or hyphen
        for (uint i = 0; i < nameBytes.length; i++) {
            bytes1 char = nameBytes[i];
            if (!(
                (char >= 0x30 && char <= 0x39) || // 0-9
                (char >= 0x61 && char <= 0x7A) || // a-z
                char == 0x2D                      // hyphen
            )) {
                revert InvalidName(normalizedName);
            }
        }
        
        // Calculate price with possible discounts
        uint256 registrationPrice = price(normalizedName);
        
        // Apply coupon discount if provided
        if (bytes(couponCode).length > 0) {
            registrationPrice = applyDiscount(registrationPrice, couponCode);
            
            // Update coupon usage
            coupons[couponCode].usedCount++;
            
            // Convert memory string to string calldata (via bytes)
            emit CouponUsed(couponCode, msg.sender, string(bytes(normalizedName)), registrationPrice);
        }
        
        // Only require payment if the sender is not the contract owner
        if (owner() != msg.sender) {
            require(msg.value >= registrationPrice, "Not enough money sent");
            
            // Calculate the split amounts (90/10)
            uint256 primaryAmount = (msg.value * 90) / 100;
            uint256 secondaryAmount = msg.value - primaryAmount; // Use subtraction to avoid rounding errors
            
            // Transfer 90% to primary treasury
            (bool success1, ) = payable(primaryTreasury).call{value: primaryAmount}('');
            require(success1, "Primary transfer failed");
            
            // Transfer 10% to secondary treasury
            (bool success2, ) = payable(secondaryTreasury).call{value: secondaryAmount}('');
            require(success2, "Secondary transfer failed");
            // Success checks done above for both transfers
        }
        
        // Create and mint the NFT
        string memory fullName = string(abi.encodePacked(normalizedName, ".", tld));
        
        // Generate the NFT image and metadata
        string memory finalSvg = string(abi.encodePacked(_svgPartOne, fullName, _svgPartTwo));
        uint256 newRecordId = _tokenIds.current();
        
        string memory json = Base64.encode(
            bytes(
                string(
                    abi.encodePacked(
                        '{"name": "',
                        fullName,
                        '", "description": "Abstract Name Service (ANS) domains are secure domain names for the Abstract blockchain ecosystem. ANS domains provide a way for users to map human readable names to blockchain and non-blockchain resources, like Abstract addresses, application resources, or website URLs. ANS domains can be bought, sold, and transferred on secondary markets as digital collectibles.", "image": "data:image/svg+xml;base64,',
                        Base64.encode(bytes(finalSvg)),
                        '","attributes": [{"trait_type": "Domain Length", "value": "',
                        StringsUpgradeable.toString(StringUtils.strlen(normalizedName)),
                        '"}]}'
                    )
                )
            )
        );
        
        string memory finalTokenUri = string(abi.encodePacked("data:application/json;base64,", json));
        
        _safeMint(msg.sender, newRecordId);
        _setTokenURI(newRecordId, finalTokenUri);
        
        // Update mappings
        domains[normalizedName] = msg.sender;
        names[newRecordId] = normalizedName;
        domainsByOwner[msg.sender].push(normalizedName);
        
        _tokenIds.increment();
    }
    
    /**
     * @dev Get domain owner's address by domain name
     */
    function getAddress(string calldata name) public view returns (address) {
        return domains[_normalizeName(name)];
    }
    
    /**
     * @dev Normalize an Ethereum address string to lowercase
     */
    function _normalizeAddress(string memory addressString) internal pure returns (string memory) {
        bytes memory addressBytes = bytes(addressString);
        bytes memory result = new bytes(addressBytes.length);
        
        // Address must be 42 characters (0x + 40 hex chars)
        require(addressBytes.length == 42, "Invalid address length");
        require(addressBytes[0] == '0' && addressBytes[1] == 'x', "Address must start with 0x");
        
        // Copy 0x prefix as is
        result[0] = addressBytes[0];
        result[1] = addressBytes[1];
        
        // Convert the rest to lowercase
        for (uint i = 2; i < 42; i++) {
            // If it's an uppercase A-F, convert to lowercase
            if (addressBytes[i] >= 0x41 && addressBytes[i] <= 0x46) {
                // ASCII A-F (65-70) to a-f (97-102)
                result[i] = bytes1(uint8(addressBytes[i]) + 32);
            } else {
                result[i] = addressBytes[i];
            }
        }
        
        return string(result);
    }
    
    /**
     * @dev Set a record for a domain
     */
    function setRecord(string calldata name, string calldata record) public {
        string memory normalizedName = _normalizeName(name);
        
        // Check NFT ownership instead of domain ownership
        uint256 tokenId;
        bool found = false;
        for (uint i = 0; i < _tokenIds.current(); i++) {
            if (keccak256(bytes(names[i])) == keccak256(bytes(normalizedName))) {
                tokenId = i;
                found = true;
                break;
            }
        }
        require(found, "Domain not found");
        require(ownerOf(tokenId) == msg.sender, "Caller is not the domain owner");
        
        // Update record and reverse lookup
        records[normalizedName] = record;
        
        // Update reverse lookup if record is a valid address
        if (bytes(record).length == 42 && bytes(record)[0] == 0x30 && bytes(record)[1] == 0x78) {
            // Normalize the address to lowercase
            string memory normalizedAddressRecord = _normalizeAddress(record);
            
            try this.toAddress(normalizedAddressRecord) returns (address recordAddress) {
                // Check if the address is already used as a record for a different domain
                address currentOwner = addressByRecord[normalizedAddressRecord];
                if (currentOwner != address(0) && currentOwner != msg.sender) {
                    // Find which domain is using this address
                    string[] memory ownerDomains = domainsByOwner[currentOwner];
                    for (uint i = 0; i < ownerDomains.length; i++) {
                        string memory domainRecord = records[ownerDomains[i]];
                        if (bytes(domainRecord).length == 42 && bytes(domainRecord)[0] == 0x30 && bytes(domainRecord)[1] == 0x78) {
                            // Normalize domain record for comparison
                            string memory normalizedDomainRecord = _normalizeAddress(domainRecord);
                            if (keccak256(bytes(normalizedDomainRecord)) == keccak256(bytes(normalizedAddressRecord))) {
                                revert AddressAlreadyInUse(ownerDomains[i]);
                            }
                        }
                    }
                }
                
                // If we get here, the address is not in use or is being used by the current user
                addressByRecord[normalizedAddressRecord] = msg.sender;
                
                // Store the normalized address as the record
                records[normalizedName] = normalizedAddressRecord;
            } catch {
                // If conversion fails, it's not a valid address
                records[normalizedName] = record; // Store original non-address record
            }
        } else {
            // If not an address format, store the original record
            records[normalizedName] = record;
        }
        
        emit RecordSet(string(bytes(normalizedName)), record, msg.sender);
    }
    
    /**
     * @dev Helper to convert string to address
     */
    function toAddress(string memory addressString) public pure returns (address) {
        bytes memory addressBytes = bytes(addressString);
        require(addressBytes.length == 42, "Invalid address length");
        require(addressBytes[0] == '0' && addressBytes[1] == 'x', "Address must start with 0x");
        
        uint256 result = 0;
        for (uint256 i = 2; i < 42; i++) {
            uint8 digit;
            // Convert hex character to value
            if (uint8(addressBytes[i]) >= 48 && uint8(addressBytes[i]) <= 57) {
                // 0-9
                digit = uint8(addressBytes[i]) - 48;
            } else if (uint8(addressBytes[i]) >= 65 && uint8(addressBytes[i]) <= 70) {
                // A-F
                digit = uint8(addressBytes[i]) - 55;
            } else if (uint8(addressBytes[i]) >= 97 && uint8(addressBytes[i]) <= 102) {
                // a-f
                digit = uint8(addressBytes[i]) - 87;
            } else {
                revert("Invalid character in address");
            }
            
            result = result * 16 + digit;
        }
        
        return address(uint160(result));
    }
    
    /**
     * @dev Get a record for a domain
     */
    function getRecord(string calldata name) public view returns (string memory) {
        return records[_normalizeName(name)];
    }
    
    /**
     * @dev Get domain name by address (reverse lookup)
     * Returns the domain name that has the given address as its record
     */
    function getNameByAddress(address addr) public view returns (string memory) {
        // Convert address to lowercase string
        string memory addrString = StringsUpgradeable.toHexString(uint256(uint160(addr)), 20);
        string memory normalizedAddrString = _normalizeAddress(addrString);
        address domainOwner = addressByRecord[normalizedAddrString];
        
        // Look through all domains owned by this address to find the one with matching record
        string[] memory ownerDomains = domainsByOwner[domainOwner];
        for (uint i = 0; i < ownerDomains.length; i++) {
            if (keccak256(bytes(records[ownerDomains[i]])) == keccak256(bytes(addrString))) {
                return ownerDomains[i];
            }
        }
        
        return "";
    }
    
    /**
     * @dev Get all registered domain names
     */
    function getAllNames() public view returns (string[] memory) {
        string[] memory allNames = new string[](_tokenIds.current());
        for (uint i = 0; i < _tokenIds.current(); i++) {
            allNames[i] = names[i];
        }
        return allNames;
    }
    
    /**
     * @dev Get all domains owned by a specific address
     */
    function getDomainsByOwner(address owner) public view returns (string[] memory) {
        return domainsByOwner[owner];
    }
    
    /**
     * @dev Create a new coupon code with discount
     */
    function createCoupon(
        string calldata couponCode, 
        uint256 discountPercentage, 
        uint256 maxUses, 
        uint256 validityInDays
    ) public onlyOwner {
        require(discountPercentage > 0 && discountPercentage <= 100, "Invalid discount percentage");
        require(maxUses > 0, "Max uses must be greater than 0");
        
        coupons[couponCode] = Coupon({
            discountPercentage: discountPercentage,
            maxUses: maxUses,
            usedCount: 0,
            isActive: true,
            validUntil: block.timestamp + validityInDays * 1 days
        });
        
        emit CouponCreated(couponCode, discountPercentage, maxUses, block.timestamp + validityInDays * 1 days);
    }
    
    /**
     * @dev Deactivate an existing coupon
     */
    function deactivateCoupon(string calldata couponCode) public onlyOwner {
        require(coupons[couponCode].isActive, "Coupon is already inactive");
        coupons[couponCode].isActive = false;
    }
    
    /**
     * @dev Migrate from old contract (burn and migrate)
     * User must approve the old contract to transfer their token to the DEAD_ADDRESS
     */
    function migrateFromOldContract(uint256 oldTokenId, string calldata newName) public {
        IERC721 oldContract = IERC721(oldContractAddress);
        
        // Verify the user owns the token in the old contract
        require(oldContract.ownerOf(oldTokenId) == msg.sender, "You don't own this token");
        
        // Get the length of the old domain from the token metadata
        string memory oldName = names[oldTokenId];
        uint oldLength = StringUtils.strlen(oldName);
        
        // Verify the new name has the same length as the old one
        // Convert calldata to memory
        string memory nameInMemory = newName;
        string memory normalizedNewName = _normalizeName(nameInMemory);
        require(StringUtils.strlen(normalizedNewName) == oldLength, "New name must have same length as old name");
        
        // Verify the new name is valid and not taken
        if (domains[normalizedNewName] != address(0)) revert AlreadyRegistered();
        
        // Manually check validity (instead of calling valid function)
        bytes memory nameBytes = bytes(normalizedNewName);
        if (nameBytes.length < 1) revert InvalidName(normalizedNewName);
        
        // Check each character is valid ASCII alphanumeric or hyphen
        for (uint i = 0; i < nameBytes.length; i++) {
            bytes1 char = nameBytes[i];
            if (!(
                (char >= 0x30 && char <= 0x39) || // 0-9
                (char >= 0x61 && char <= 0x7A) || // a-z
                char == 0x2D                      // hyphen
            )) {
                revert InvalidName(normalizedNewName);
            }
        }
        
        // Transfer the old token to the DEAD_ADDRESS (burns it)
        try oldContract.transferFrom(msg.sender, DEAD_ADDRESS, oldTokenId) {
            // Register the new name for free
            // Create and mint the NFT
            string memory fullName = string(abi.encodePacked(normalizedNewName, ".", tld));
            
            // Generate the NFT image and metadata
            string memory finalSvg = string(abi.encodePacked(_svgPartOne, fullName, _svgPartTwo));
            uint256 newRecordId = _tokenIds.current();
            
            string memory json = Base64.encode(
                bytes(
                    string(
                        abi.encodePacked(
                            '{"name": "',
                            fullName,
                            '", "description": "Abstract Name Service (ANS) domains are secure domain names for the Abstract blockchain ecosystem. ANS domains provide a way for users to map human readable names to blockchain and non-blockchain resources, like Abstract addresses, application resources, or website URLs. ANS domains can be bought, sold, and transferred on secondary markets as digital collectibles.", "image": "data:image/svg+xml;base64,',
                            Base64.encode(bytes(finalSvg)),
                            '","attributes": [{"trait_type": "Domain Length", "value": "',
                            StringsUpgradeable.toString(StringUtils.strlen(normalizedNewName)),
                            '"},{"trait_type": "Migrated", "value": "Yes"}]}'
                        )
                    )
                )
            );
            
            string memory finalTokenUri = string(abi.encodePacked("data:application/json;base64,", json));
            
            _safeMint(msg.sender, newRecordId);
            _setTokenURI(newRecordId, finalTokenUri);
            
            // Update mappings
            domains[normalizedNewName] = msg.sender;
            names[newRecordId] = normalizedNewName;
            domainsByOwner[msg.sender].push(normalizedNewName);
            
            _tokenIds.increment();
            
            emit DomainMigrated(string(bytes(oldName)), msg.sender, string(bytes(normalizedNewName)));
        } catch {
            revert MigrationFailed();
        }
    }
    
    /**
     * @dev Update the SVG styling for the NFT images
     */
    /**
     * @dev Update the SVG styling for the NFT images (original function for compatibility)
     */
    function updateNftStyling(string calldata svgPartOne, string calldata svgPartTwo) public onlyOwner {
        _svgPartOne = svgPartOne;
        _svgPartTwo = svgPartTwo;
    }
    
    /**
     * @dev Update the background image URL for NFTs
     */
    function updateBackgroundImageUrl(string memory newBackgroundImageUrl) public onlyOwner {
        _backgroundImageUrl = newBackgroundImageUrl;
        
        // Update _svgPartOne to incorporate the new background image URL
        _svgPartOne = string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 1000 1000">',
            '<defs>',
            '<style>',
            '.domain-name{font-family:Arial,sans-serif;font-weight:normal;fill:#ffffff;text-anchor:start;}',
            '.tld-text{font-family:Arial,sans-serif;font-weight:normal;fill:#a8aba9;text-anchor:start;}',
            '</style>',
            '</defs>',
            '<image href="', _backgroundImageUrl, '" width="1000" height="1000"/>',
            '<text x="50" y="900" class="domain-name" font-size="38">'
        ));
    }
    
    /**
     * @dev Update the primary treasury address (90% recipient)
     */
    function updatePrimaryTreasury(address newTreasury) public onlyOwner {
        primaryTreasury = newTreasury;
    }
    
    /**
     * @dev Update the secondary treasury address (10% recipient)
     */
    function updateSecondaryTreasury(address newTreasury) public onlyOwner {
        secondaryTreasury = newTreasury;
    }
    
    /**
     * @dev Update the old contract address
     */
    function updateOldContractAddress(address newAddress) public onlyOwner {
        oldContractAddress = newAddress;
    }
    
    /**
     * @dev Withdraw any stuck ETH in the contract
     */
    function withdraw() public onlyOwner {
        (bool success, ) = payable(owner()).call{value: address(this).balance}('');
        require(success, "Transfer failed");
    }
    
    /**
     * @dev Returns the contract URI for marketplaces like OpenSea
     * This contains collection-level metadata including the collection avatar
     */
    function contractURI() public view returns (string memory) {
        return _contractURI;
    }
    
    /**
     * @dev Update the contract URI for collection-level metadata
     * @param avatarUrl The URL to the collection avatar image
     * @param description Optional description text (pass empty string to keep existing)
     */
    function updateCollectionMetadata(string memory avatarUrl, string memory description) public onlyOwner {
        string memory descriptionText = bytes(description).length > 0 
            ? description 
            : "Abstract Name Service (ANS) domains are secure domain names for the Abstract blockchain ecosystem. ANS domains provide a way for users to map human readable names to blockchain and non-blockchain resources, like Abstract addresses, application resources, or website URLs. ANS domains can be bought, sold, and transferred on secondary markets as digital collectibles.";
            
        string memory collectionJson = string(abi.encodePacked(
            '{',
            '"name": "ANS: Abstract Name Service",',
            '"description": "', descriptionText, '",',
            '"image": "', avatarUrl, '",',
            '"external_link": "",',
            '"seller_fee_basis_points": 0,',
            '"fee_recipient": ""',
            '}'
        ));
        _contractURI = string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(collectionJson))));
    }
}
