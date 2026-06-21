import XCTest
@testable import MadFrogVPN

/// A8 (PRODUCT-MATURITY-LOOP, 2026-06-21). The FreeKassa paywall now shows an
/// effective per-month price + "save X%" vs the monthly plan so a longer plan
/// reads as the better deal. This pins the pure pricing math.
///
/// Real prices today: 229₽/mo, 599₽/3mo, 1099₽/6mo, 1999₽/yr.
final class PlanPricingTests: XCTestCase {

    func testPerMonthRub() {
        XCTAssertEqual(PlanPricing.perMonthRub(priceRub: 229, days: 30), 229)
        XCTAssertEqual(PlanPricing.perMonthRub(priceRub: 599, days: 90), 200)   // 599 / 3
        XCTAssertEqual(PlanPricing.perMonthRub(priceRub: 1099, days: 180), 183) // 1099 / 6 = 183.2 → 183
        XCTAssertEqual(PlanPricing.perMonthRub(priceRub: 1999, days: 365), 164) // 1999 / (365/30) = 164.3 → 164
    }

    func testPerMonthGuards() {
        XCTAssertEqual(PlanPricing.perMonthRub(priceRub: 0, days: 30), 0)
        XCTAssertEqual(PlanPricing.perMonthRub(priceRub: 599, days: 0), 0)
        XCTAssertEqual(PlanPricing.perMonthRub(priceRub: -1, days: 30), 0)
    }

    func testBaselineIsCostliestPerMonth() {
        let plans = [(229, 30), (599, 90), (1099, 180), (1999, 365)]
        XCTAssertEqual(PlanPricing.baselinePerMonthRub(plans), 229) // monthly is the priciest per-month
    }

    func testBaselineEmpty() {
        XCTAssertEqual(PlanPricing.baselinePerMonthRub([]), 0)
    }

    func testSavingsPercent() {
        // annual 164/mo vs 229/mo baseline → ~28% off
        XCTAssertEqual(PlanPricing.savingsPercent(perMonthRub: 164, baselinePerMonthRub: 229), 28)
        // 3-month 200/mo vs 229 → ~13%
        XCTAssertEqual(PlanPricing.savingsPercent(perMonthRub: 200, baselinePerMonthRub: 229), 13)
    }

    func testNoSavingsForBaselineOrBadInput() {
        XCTAssertEqual(PlanPricing.savingsPercent(perMonthRub: 229, baselinePerMonthRub: 229), 0)
        XCTAssertEqual(PlanPricing.savingsPercent(perMonthRub: 300, baselinePerMonthRub: 229), 0) // more expensive → no "saving"
        XCTAssertEqual(PlanPricing.savingsPercent(perMonthRub: 100, baselinePerMonthRub: 0), 0)
    }
}
