import Foundation

/// Pure pricing math for the FreeKassa (web) paywall plan cards.
/// A8 (PRODUCT-MATURITY-LOOP, 2026-06-21): the funnel showed only the raw "599 ₽"
/// per plan, so users defaulted to the cheapest visible number (the monthly,
/// highest-churn/lowest-LTV option) because nothing showed that a longer plan is
/// cheaper PER MONTH. This surfaces an effective per-month price + a "save X%"
/// vs the costliest-per-month (monthly) plan, nudging toward commitment.
///
/// Foundation-only and pure so it is unit-testable (and `swiftc -parse`-checkable
/// without the iOS SDK).
enum PlanPricing {
    /// Effective price per 30 days, rounded to the nearest ruble. days <= 0 → 0.
    static func perMonthRub(priceRub: Int, days: Int) -> Int {
        guard days > 0, priceRub > 0 else { return 0 }
        let months = Double(days) / 30.0
        guard months > 0 else { return 0 }
        return Int((Double(priceRub) / months).rounded())
    }

    /// The baseline per-month price = the MAX per-month across plans (i.e. the
    /// shortest / monthly plan, the most expensive way to buy). 0 if empty.
    static func baselinePerMonthRub(_ plans: [(priceRub: Int, days: Int)]) -> Int {
        plans
            .map { perMonthRub(priceRub: $0.priceRub, days: $0.days) }
            .filter { $0 > 0 }
            .max() ?? 0
    }

    /// Savings percent of `perMonthRub` vs `baselinePerMonthRub`, rounded.
    /// 0 when there is no real saving (the baseline plan itself, or bad input).
    static func savingsPercent(perMonthRub: Int, baselinePerMonthRub: Int) -> Int {
        guard baselinePerMonthRub > 0, perMonthRub > 0, perMonthRub < baselinePerMonthRub else {
            return 0
        }
        let frac = 1.0 - Double(perMonthRub) / Double(baselinePerMonthRub)
        return Int((frac * 100).rounded())
    }
}
