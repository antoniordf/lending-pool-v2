// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// imports

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
// import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract LendingPool is
    ERC20("PoolToken", "PT"),
    ReentrancyGuard,
    Pausable,
    OwnableUpgradeable
{
    /********************************************************************************************/
    /*                                         OVERRIDES                                        */
    /********************************************************************************************/
    // Explicitly override conflicting functions
    function _msgSender()
        internal
        view
        override(Context, ContextUpgradeable)
        returns (address)
    {
        return ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        override(Context, ContextUpgradeable)
        returns (bytes calldata)
    {
        return ContextUpgradeable._msgData();
    }

    /********************************************************************************************/
    /*                                       DATA VARIABLES                                     */
    /********************************************************************************************/

    // This represents the stablecoin (e.g., USDC) being supplied to and borrowed from the pool.
    IERC20 public stableCoin;

    // This represents the ERC115 principal token that the loanRouter will swap the stablecoins with
    IERC1155 public principalToken;

    // The loanRouter is the contract that interfaces between the pool and the loan contract.
    address public loanRouter;

    // The interest rate strategy contract
    IInterestRateStrategy public interestRateStrategy;

    // add runningTotalQty uint

    /********************************************************************************************/
    /*                                       EVENT DEFINITIONS                                  */
    /********************************************************************************************/

    event Deposited(address indexed user, uint256 amount);
    event Borrowed(address indexed borrower, uint256 amount);
    event PoolTokensMinted(address indexed lender, uint256 poolTokens);
    event Withdrawal(address indexed lender, uint256 amount);
    event TokenBurned(address indexed lender, uint256 tokenAmount);

    /********************************************************************************************/
    /*                                       FUNCTION MODIFIERS                                 */
    /********************************************************************************************/

    modifier onlyLoanRouter() {
        require(msg.sender == loanRouter, "Caller is not authorized");
        _;
    }

    /********************************************************************************************/
    /*                                       CONSTRUCTOR                                        */
    /********************************************************************************************/

    constructor(
        address _stableCoin,
        address _principalToken,
        address _loanRouter,
        address _interestRateStrategy
    ) {
        stableCoin = IERC20(_stableCoin);
        loanRouter = _loanRouter;
        principalToken = IERC1155(_principalToken);
        interestRateStrategy = IInterestRateStrategy(_interestRateStrategy);
    }

    /********************************************************************************************/
    /*                                       UTILITY FUNCTIONS                                  */
    /********************************************************************************************/

    /**
     * @dev This function allows the owner to set the address of the loanRouter.
     */
    function setLoanRouter(address _loanRouter) external onlyOwner {
        loanRouter = _loanRouter;
    }

    /**
     * @dev This function allows the owner to set the address of the principalToken.
     */
    function setDebtToken(address _principalToken) external onlyOwner {
        principalToken = IERC1155(_principalToken);
    }

    /********************************************************************************************/
    /*                                     SMART CONTRACT FUNCTIONS                             */
    /********************************************************************************************/

    /**
     * @dev Called by lender to deposit funds into the pool.
     */

    function deposit(
        uint256 _amount,
        address _recipient
    ) external whenNotPaused nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        require(_recipient != address(0), "Recipient cannot be 0 address");

        // Re-calculate the interest rates
        interestRateStrategy.calculateInterestRates(
            address(stableCoin),
            address(this),
            _amount,
            0
        );

        // transfer stablecoins
        require(
            stableCoin.transferFrom(msg.sender, address(this), _amount),
            "Transfer failed"
        );
        emit Deposited(msg.sender, _amount);

        // Calculate the proportional number of poolTokens to be minted and mint tokens to lender's address
        uint256 poolTokens = (totalSupply() == 0)
            ? _amount
            : (_amount * totalSupply()) / address(this).balance;
        _mint(msg.sender, poolTokens);
        emit PoolTokensMinted(msg.sender, poolTokens);
    }

    /**
     * @dev Called by lender to withdraw funds into the pool.
     */

    function withdraw(uint256 _amount) external whenNotPaused nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        require(
            _amount <= address(this).balance,
            "Amount exceeds pool balance"
        );

        // Re-calculate the interest rates
        interestRateStrategy.calculateInterestRates(
            address(stableCoin),
            address(this),
            0,
            _amount
        );

        // Calculate maximum amount of stable coins the lender can withdraw
        uint256 maxWithdrawal = (balanceOf(msg.sender) *
            address(this).balance) / totalSupply();
        require(_amount <= maxWithdrawal, "Withdrawal exceeds allowed amount");

        // Calculating how many pool tokens need to be burned
        uint256 requiredPoolTokens = (_amount * totalSupply()) /
            address(this).balance;

        // Burns the pool tokens directly at the lender's address
        _burn(msg.sender, requiredPoolTokens);
        emit TokenBurned(msg.sender, requiredPoolTokens);

        // transfers stablecoins to caller in proportion to the tokens he sent
        stableCoin.transfer(msg.sender, _amount);
        emit Withdrawal(msg.sender, _amount);
    }

    /**
     * @dev This function collects the repayments that the borrower has made to the loan contract.
     * The function is called by the loan router when the borrower repays loans or interest.
     * This function calls the collectPayment function in the loan contract.
     * @param _loanContract The address of the loan contract.
     * @param _tokenId The ID of the principal token.
     */
    function collectPayment(
        address _loanContract,
        uint256 _tokenId
    ) external whenNotPaused onlyLoanRouter {
        // Get the balance of debt tokens held by this contract
        uint256 principalTokenBalance = principalToken.balanceOf(
            address(this),
            _tokenId
        );

        // Dynamically cast the address of the ILoanContract interface
        ILoanContract loanContract = ILoanContract(_loanContract);

        // Re-calculate the interest rates
        // TODO

        // Call the collectPayment function in the loan contract
        loanContract.redeem(principalTokenBalance);
    }

    /**
     * @dev Called by the loanRouter. This function accepts the principal token and sends the borrowed funds to the loanRouter.
     */
    function borrow(
        address _borrower,
        uint256 _amount,
        uint256 _principalTokenAmount
    ) external onlyLoanRouter whenNotPaused {
        require(
            _amount <= address(this).balance,
            "Not enough funds in the pool"
        );

        // Re-calculate the interest rates
        interestRateStrategy.calculateInterestRates(
            address(stableCoin),
            address(this),
            0,
            _amount
        );

        // Accept the debt tokens from the loanRouter.
        require(
            principalToken.transferFrom(
                msg.sender,
                address(this),
                _principalTokenAmount
            ),
            "Transfer of debt tokens failed"
        );

        // Transfer the requested stableCoin or ETH to the loanRouter.
        require(
            stableCoin.transfer(msg.sender, _amount),
            "StableCoin transfer failed"
        );
        emit Borrowed(_borrower, _amount);
    }

    // function viewInterestRate() public view {
    //     // qtyA: read totalSupply of PoolTokens
    //     // qtyB: read total balance of PrincipalTokens (ERC1155) inside this contract (might be challenging without knowing all IDs)
    //     // calculate utilisation  (qtyB / qtyA)
    //     // utilisation => interest rate
    // }
}

/********************************************************************************************/
/*                                      INTERFACES                                          */
/********************************************************************************************/

interface ILoanContract {
    function collectPayment(uint256 debtTokenBalance) external;
}

interface IInterestRateStrategy {
    function calculateInterestRates(
        address _asset,
        address _poolToken,
        uint256 _liquidityAdded,
        uint256 _liquidityTaken
    ) external view returns (uint256, uint256, uint256);
}
