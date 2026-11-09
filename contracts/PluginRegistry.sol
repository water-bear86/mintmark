// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Address.sol";

/// @title PluginRegistry (MintMark)
/// @notice The marketplace's listing book (docs/PLUGIN-MARKETPLACE-SPEC.md §D5). Plugins work without being
///         listed — the launchpad gates nothing on this registry — so a listing is pure disclosure: a name, a
///         metadata URI, and the author's self-declared fee take. The site renders the browse/pick UI and the
///         badges from it. `verified` is the one curated bit, set only by the curator after review; any author
///         edit clears it, so a badge always refers to what was reviewed.
/// @dev Listings never gate fees or trades, so the worst a bad listing can do is mislead a reader until it is
///      unverified or delisted. One listing per plugin address at a time; the curator can delist a squatted or
///      abandoned record so the rightful author can list again (review #1 M1/#4: listing requires no proof of
///      authorship, so first-come squatting must be recoverable). The curator verifies a listing only after
///      checking the author is who they expect — and `verified` refers to the reviewed bytecode of that address,
///      so the curator should not verify upgradeable proxies (review #1 note).
contract PluginRegistry {
    struct Listing {
        address plugin;
        address author;
        /// @notice The author's self-declared cut of fees routed through the plugin, in basis points. Pure
        ///         disclosure: the plugin's code is what actually takes it.
        uint16 authorFeeBps;
        bool verified;
        uint64 listedAt;
        string name;
        string metadataURI;
    }

    uint256 public constant MAX_LISTING_FEE = 0.05 ether;

    address public curator;
    uint256 public listingFee;
    uint256 public pendingFees;

    mapping(address plugin => Listing) private _listings;
    address[] private _plugins;

    event Listed(address indexed plugin, address indexed author, string name, string metadataURI, uint16 authorFeeBps);
    event ListingUpdated(address indexed plugin, string metadataURI, uint16 authorFeeBps);
    event Verified(address indexed plugin, bool verified);
    event Delisted(address indexed plugin);
    event CuratorUpdated(address indexed curator);
    event ListingFeeUpdated(uint256 fee);
    event FeesCollected(address indexed to, uint256 amount);

    error ZeroAddress();
    error Forbidden();
    error AlreadyListed(address plugin);
    error NotListed(address plugin);
    error InvalidName();
    error InvalidMetadata();
    error FeeTooHigh();
    error WrongValue(uint256 fee, uint256 value);
    /// @notice A disclosed author fee above 100% is necessarily a lie.
    error InvalidAuthorFeeBps(uint16 bps);
    /// @notice Renouncing the curator with listing fees still pending would strand them: collect first.
    error FeesPending();

    constructor(address curator_, uint256 listingFee_) {
        if (curator_ == address(0)) revert ZeroAddress();
        if (listingFee_ > MAX_LISTING_FEE) revert FeeTooHigh();
        curator = curator_;
        listingFee = listingFee_;
    }

    // ─── Listing (permissionless) ────────────────────────────────────────────

    /// @notice Lists `plugin` under the caller as its author, against the exact listing fee. Once per plugin.
    function list(address plugin, string calldata name, string calldata metadataURI, uint16 authorFeeBps)
        external
        payable
    {
        if (plugin == address(0)) revert ZeroAddress();
        if (_listings[plugin].plugin != address(0)) revert AlreadyListed(plugin);
        if (bytes(name).length == 0 || bytes(name).length > 48) revert InvalidName();
        if (bytes(metadataURI).length > 256) revert InvalidMetadata();
        if (authorFeeBps > 10_000) revert InvalidAuthorFeeBps(authorFeeBps);
        if (msg.value != listingFee) revert WrongValue(listingFee, msg.value);
        pendingFees += msg.value;

        _listings[plugin] = Listing({
            plugin: plugin,
            author: msg.sender,
            authorFeeBps: authorFeeBps,
            verified: false,
            listedAt: uint64(block.timestamp),
            name: name,
            metadataURI: metadataURI
        });
        _plugins.push(plugin);
        emit Listed(plugin, msg.sender, name, metadataURI, authorFeeBps);
    }

    /// @notice The author updates the mutable parts of their listing. Any update clears `verified`: the badge
    ///         always refers to what the curator reviewed.
    function update(address plugin, string calldata metadataURI, uint16 authorFeeBps) external {
        Listing storage l = _listings[plugin];
        if (l.plugin == address(0)) revert NotListed(plugin);
        if (msg.sender != l.author) revert Forbidden();
        if (bytes(metadataURI).length > 256) revert InvalidMetadata();
        if (authorFeeBps > 10_000) revert InvalidAuthorFeeBps(authorFeeBps);
        l.metadataURI = metadataURI;
        l.authorFeeBps = authorFeeBps;
        if (l.verified) {
            l.verified = false;
            emit Verified(plugin, false);
        }
        emit ListingUpdated(plugin, metadataURI, authorFeeBps);
    }

    // ─── Curation ────────────────────────────────────────────────────────────

    function setVerified(address plugin, bool verified) external {
        if (msg.sender != curator) revert Forbidden();
        Listing storage l = _listings[plugin];
        if (l.plugin == address(0)) revert NotListed(plugin);
        l.verified = verified;
        emit Verified(plugin, verified);
    }

    /// @notice Removes a listing (a squatted record, a dead plugin), freeing the address to be listed again by
    ///         the right party. Curation only: authors who want their record gone ask the curator.
    function delist(address plugin) external {
        if (msg.sender != curator) revert Forbidden();
        if (_listings[plugin].plugin == address(0)) revert NotListed(plugin);
        delete _listings[plugin];
        uint256 len = _plugins.length;
        for (uint256 i = 0; i < len; i++) {
            if (_plugins[i] == plugin) {
                _plugins[i] = _plugins[len - 1];
                _plugins.pop();
                break;
            }
        }
        emit Delisted(plugin);
    }

    /// @notice Setting the zero address is an irreversible renounce: listings stay, badges freeze. Renouncing
    ///         requires the pending listing fees to have been collected first, or they would strand forever.
    function setCurator(address curator_) external {
        if (msg.sender != curator) revert Forbidden();
        if (curator_ == address(0) && pendingFees != 0) revert FeesPending();
        curator = curator_;
        emit CuratorUpdated(curator_);
    }

    function setListingFee(uint256 fee) external {
        if (msg.sender != curator) revert Forbidden();
        if (fee > MAX_LISTING_FEE) revert FeeTooHigh();
        listingFee = fee;
        emit ListingFeeUpdated(fee);
    }

    /// @notice Permissionless: sends the accrued listing fees to the curator.
    function collectFees() external returns (uint256 amount) {
        address to = curator;
        if (to == address(0)) revert ZeroAddress();
        amount = pendingFees;
        if (amount == 0) return 0;
        pendingFees = 0;
        emit FeesCollected(to, amount);
        Address.sendValue(payable(to), amount);
    }

    // ─── Views ───────────────────────────────────────────────────────────────

    function listingOf(address plugin) external view returns (Listing memory) {
        if (_listings[plugin].plugin == address(0)) revert NotListed(plugin);
        return _listings[plugin];
    }

    function isListed(address plugin) external view returns (bool) {
        return _listings[plugin].plugin != address(0);
    }

    function pluginsLength() external view returns (uint256) {
        return _plugins.length;
    }

    function pluginAt(uint256 index) external view returns (address) {
        return _plugins[index];
    }

    /// @param count Clamped to 100 to bound gas.
    function page(uint256 start, uint256 count) external view returns (Listing[] memory result) {
        if (count > 100) count = 100;
        uint256 len = _plugins.length;
        if (start >= len) return new Listing[](0);
        uint256 end = start + count;
        if (end > len) end = len;
        result = new Listing[](end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = _listings[_plugins[i]];
        }
    }
}
