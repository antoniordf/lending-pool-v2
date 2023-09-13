// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LendingPool} from "./LendingPool.sol";
import {WadRayMath} from "./WadRayMath.sol";
import {PercentageMath} from "./PercentageMath.sol";

contract InterestRateStrategy {
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    /********************************************************************************************/
    /*                                       DATA VARIABLES                                     */
    /********************************************************************************************/

    /**
     * @notice Returns the usage ratio at which the pool aims to obtain most competitive borrow rates.
     * @return The optimal usage ratio, expressed in ray.
     */
    uint256 public immutable OPTIMAL_USAGE_RATIO;

    /**
     * @notice Returns the excess usage ratio above the optimal.
     * @dev It's always equal to 1-optimal usage ratio (added as constant for gas optimizations)
     * @return The max excess usage ratio, expressed in ray.
     */
    uint256 public immutable MAX_EXCESS_USAGE_RATIO;

    // Base stable borrow rate when usage rate = 0. Expressed in ray
    uint256 internal immutable _baseStableBorrowRate;

    // Slope of the stable interest curve when usage ratio > 0 and <= OPTIMAL_USAGE_RATIO. Expressed in ray
    uint256 internal immutable _stableRateSlope1;

    // Slope of the variable interest curve when usage ratio > OPTIMAL_USAGE_RATIO. Expressed in ray
    uint256 internal immutable _stableRateSlope2;

    struct CalcInterestRatesLocalVars {
        uint256 availableLiquidity;
        uint256 totalDebt;
        uint256 currentStableBorrowRate;
        uint256 currentLiquidityRate;
        uint256 usageRatio;
        uint256 availableLiquidityPlusDebt;
        uint256 couponPremiumRate;
        uint256 collateralInsurancePremiumRate;
    }

    /********************************************************************************************/
    /*                                       CONSTRUCTOR                                        */
    /********************************************************************************************/

    /**
     * @dev Constructor.
     * @param optimalUsageRatio The optimal usage ratio
     * @param baseStableBorrowRate The base variable borrow rate
     * @param stableRateSlope1 The variable rate slope below optimal usage ratio
     * @param stableRateSlope2 The variable rate slope above optimal usage ratio
     */
    constructor(
        uint256 optimalUsageRatio,
        uint256 baseStableBorrowRate,
        uint256 stableRateSlope1,
        uint256 stableRateSlope2
    ) {
        require(
            WadRayMath.RAY >= optimalUsageRatio,
            "INVALID_OPTIMAL_USAGE_RATIO"
        );
        OPTIMAL_USAGE_RATIO = optimalUsageRatio;
        MAX_EXCESS_USAGE_RATIO = WadRayMath.RAY - optimalUsageRatio;
        _baseStableBorrowRate = baseStableBorrowRate;
        _stableRateSlope1 = stableRateSlope1;
        _stableRateSlope2 = stableRateSlope2;
    }

    /********************************************************************************************/
    /*                                   CONTRACT FUNCTIONS                                     */
    /********************************************************************************************/

    /**
     * @notice Calculates the interest rates depending on the reserve's state and configurations
     * @return liquidityRate The liquidity rate expressed in rays - The liquidity rate is the rate paid to lenders on the protocol
     * @return stableBorrowRate The stable borrow rate expressed in rays
     * @return variableBorrowRate The variable borrow rate expressed in rays
     */
    function calculateInterestRates(
        address _asset,
        address _poolToken,
        uint256 _liquidityAdded,
        uint256 _liquidityTaken
    ) public view returns (uint256, uint256, uint256) {
        CalcInterestRatesLocalVars memory vars;

        vars.currentLiquidityRate = 0;
        vars.currentStableBorrowRate = _baseStableBorrowRate;

        if (vars.totalDebt != 0) {
            vars.availableLiquidity =
                IERC20(_asset).balanceOf(_poolToken) +
                _liquidityAdded -
                _liquidityTaken;

            vars.availableLiquidityPlusDebt =
                vars.availableLiquidity +
                vars.totalDebt;
            vars.usageRatio = vars.totalDebt.rayDiv(
                vars.availableLiquidityPlusDebt
            );
        }

        if (vars.usageRatio > OPTIMAL_USAGE_RATIO) {
            uint256 excessBorrowUsageRatio = (vars.usageRatio -
                OPTIMAL_USAGE_RATIO).rayDiv(MAX_EXCESS_USAGE_RATIO);

            vars.currentStableBorrowRate +=
                _stableRateSlope1 +
                _stableRateSlope2.rayMul(excessBorrowUsageRatio);
        } else {
            vars.currentStableBorrowRate += _stableRateSlope1
                .rayMul(vars.usageRatio)
                .rayDiv(OPTIMAL_USAGE_RATIO);
        }

        vars.currentLiquidityRate = vars
            .currentStableBorrowRate
            .rayMul(vars.usageRatio)
            .percentMul(PercentageMath.PERCENTAGE_FACTOR);

        return (vars.currentLiquidityRate, vars.currentStableBorrowRate);
    }

    /**
     * @notice Adds the respective risk spreads on top of the base interest rates in order to calculate the final rates.
     * @param paysCoupon Flag that indicates if the user is paying the interest rate coupon
     * @param isCollateralInsured Flag that indicates if the collateral is insured
     * @return liquidityRate The liquidity rate expressed in rays - The liquidity rate is the rate paid to lenders on the protocol
     * @return finalStableBorrowRate The stable borrow rate expressed in rays after adding the premiums
     */
    function riskAdjustedRate(
        bool paysCoupon,
        bool isCollateralInsured
    ) external pure returns (uint256, uint256, uint256) {
        CalcInterestRatesLocalVars memory vars;

        uint256 couponPremium = paysCoupon ? 0 : vars.couponPremiumRate;
        uint256 collateralPremium = isCollateralInsured
            ? 0
            : vars.collateralInsurancePremiumRate;

        uint256 finalStableBorrowRate = vars.currentStableBorrowRate +
            couponPremium +
            collateralPremium;

        return (vars.currentLiquidityRate, finalStableBorrowRate);
    }
}
