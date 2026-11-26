import AppIntents
import StoreKit
import StoreKitTest
import XCTest
@testable import PianoMetronome

final class MetronomeIntegrationTests: XCTestCase {
    @MainActor
    func testAnnualProductOffersOneWeekFreeToNewSubscriber() async throws {
        let session = try await freshStore()
        defer { session.clearTransactions() }

        let product = try await annualProduct()
        let subscription = try XCTUnwrap(product.subscription)
        let offer = try XCTUnwrap(subscription.introductoryOffer)
        let eligible = await subscription.isEligibleForIntroOffer

        XCTAssertEqual(product.type, .autoRenewable)
        XCTAssertEqual(product.price, Decimal(string: "0.99"))
        XCTAssertEqual(subscription.subscriptionPeriod.unit, .year)
        XCTAssertEqual(subscription.subscriptionPeriod.value, 1)
        XCTAssertEqual(offer.paymentMode, .freeTrial)
        XCTAssertEqual(offer.period.unit, .week)
        XCTAssertEqual(offer.period.value, 1)
        XCTAssertEqual(offer.periodCount, 1)
        XCTAssertEqual(offer.price, 0)
        XCTAssertTrue(eligible)
    }

    @MainActor
    func testTrialUnlocksAndFreeTrialIsNotGrantedTwice() async throws {
        let session = try await freshStore()
        defer { session.clearTransactions() }

        let access = MetronomeSubscription()
        await access.refresh()
        XCTAssertThrowsError(try access.requireAccess())

        let product = try await annualProduct()
        let paidResult = try await product.purchase()
        guard case .success(let verification) = paidResult,
              case .verified(let transaction) = verification else {
            return XCTFail("StoreKit did not return a verified annual purchase")
        }
        try await waitForStoreEntitlements([product.id])
        let accepted = await access.accept(verification)
        XCTAssertTrue(accepted)
        XCTAssertTrue(access.hasAccess)
        XCTAssertFalse(access.ownsLifetime)
        if #available(iOS 17.2, *) {
            XCTAssertEqual(transaction.offer?.type, .introductory)
            XCTAssertEqual(transaction.offer?.paymentMode, .freeTrial)
        }
        let subscription = try XCTUnwrap(product.subscription)
        let eligibleAfterPurchase = await subscription.isEligibleForIntroOffer
        XCTAssertFalse(eligibleAfterPurchase)
    }

    @MainActor
    func testPendingPurchaseOnlyUnlocksAfterApproval() async throws {
        let session = try await freshStore()
        defer {
            session.resetToDefaultState()
            session.clearTransactions()
        }

        session.askToBuyEnabled = true
        let product = try await annualProduct()
        let access = MetronomeSubscription()
        guard case .pending = try await product.purchase() else {
            return XCTFail("Expected an Ask to Buy purchase to be pending")
        }
        await access.refresh()
        XCTAssertThrowsError(try access.requireAccess())

        let pending = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == product.id })
        let pendingID = pending.identifier
        try await simulateStoreEvent { try session.approveAskToBuyTransaction(identifier: pendingID) }
        try await waitForStoreEntitlements([product.id])
        try await access.verifyAccess()
        XCTAssertFalse(access.ownsLifetime)
    }

    @MainActor
    func testAnnualRenewalCancellationAndExpiration() async throws {
        let session = try await freshStore()
        defer { session.clearTransactions() }

        let id = MetronomeSubscription.annualProductID
        let access = MetronomeSubscription()
        try await session.buyProduct(identifier: id)
        try await waitForStoreEntitlements([id])
        try await access.verifyAccess()
        let original = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == id })
        try await simulateStoreEvent { try session.forceRenewalOfSubscription(productIdentifier: id) }
        try await access.verifyAccess()
        let transactions = session.allTransactions().filter { $0.productIdentifier == id }
        XCTAssertGreaterThanOrEqual(transactions.count, 2)
        let renewal = try XCTUnwrap(transactions.first { $0.identifier != original.identifier })

        let renewalID = renewal.identifier
        try await simulateStoreEvent { try session.disableAutoRenewForTransaction(identifier: renewalID) }
        try await access.verifyAccess()
        var didLoseAccess = false
        access.onAccessLost = { didLoseAccess = true }
        try await simulateStoreEvent { try session.expireSubscription(productIdentifier: id) }
        try await waitForStoreEntitlements([])
        await access.refresh()
        XCTAssertTrue(didLoseAccess)
        XCTAssertThrowsError(try access.requireAccess())
    }

    @MainActor
    func testLifetimePurchaseRestoreAndRefund() async throws {
        let session = try await freshStore()
        defer { session.clearTransactions() }

        let id = MetronomeSubscription.lifetimeProductID
        let products = try await Product.products(for: [id])
        let product = try XCTUnwrap(products.first)
        XCTAssertEqual(product.type, .nonConsumable)
        XCTAssertEqual(product.price, Decimal(string: "1.99"))
        let access = MetronomeSubscription()
        guard case .success(let verification) = try await product.purchase(),
              case .verified(let transaction) = verification else {
            return XCTFail("StoreKit did not return a verified lifetime purchase")
        }
        try await waitForStoreEntitlements([product.id])
        let accepted = await access.accept(verification)
        XCTAssertTrue(accepted)
        XCTAssertTrue(access.ownsLifetime)

        try await AppStore.sync()
        let restored = MetronomeSubscription()
        try await restored.verifyAccess()
        XCTAssertTrue(restored.ownsLifetime)

        let purchase = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == id && UInt64($0.identifier) == transaction.id })
        let purchaseID = purchase.identifier
        try await simulateStoreEvent { try session.refundTransaction(identifier: purchaseID) }
        try await waitForStoreEntitlements([])
        await access.refresh()
        XCTAssertFalse(access.ownsLifetime)
        XCTAssertThrowsError(try access.requireAccess())
    }

    @MainActor
    func testLifetimeAccessSurvivesAnnualExpiration() async throws {
        let session = try await freshStore()
        defer { session.clearTransactions() }

        let annualID = MetronomeSubscription.annualProductID
        let lifetimeID = MetronomeSubscription.lifetimeProductID
        try await session.buyProduct(identifier: annualID)
        try await session.buyProduct(identifier: lifetimeID)
        try await waitForStoreEntitlements([annualID, lifetimeID])
        let access = MetronomeSubscription()
        try await access.verifyAccess()
        XCTAssertTrue(access.ownsLifetime)

        try await simulateStoreEvent { try session.expireSubscription(productIdentifier: annualID) }
        try await waitForStoreEntitlements([lifetimeID])
        try await access.verifyAccess()
        XCTAssertTrue(access.ownsLifetime)
    }

    @MainActor
    func testEntitlementGuardsURLAndShortcutsAndExpiryStopsPlayback() async throws {
        let session = try await freshStore()
        defer { session.clearTransactions() }

        let metronome = Metronome.shared
        defer { metronome.stop() }
        let url = try XCTUnwrap(URL(string: "bytereset-metronome://start?bpm=137&beats=5&unit=4"))
        await metronome.handle(url)
        XCTAssertFalse(metronome.playing)
        XCTAssertNotNil(metronome.error)
        do {
            _ = try await StartMetronomeIntent().perform()
            XCTFail("App Intent started playback without an entitlement")
        } catch MetronomeError.subscriptionRequired {}

        let annualID = MetronomeSubscription.annualProductID
        try await session.buyProduct(identifier: annualID)
        try await waitForStoreEntitlements([annualID])
        metronome.error = nil
        await metronome.handle(url)
        XCTAssertNil(metronome.error)
        XCTAssertTrue(metronome.playing)
        XCTAssertEqual(metronome.settings.bpm, 137)
        XCTAssertEqual(metronome.settings.beats, 5)
        let stop = try XCTUnwrap(URL(string: "bytereset-metronome://stop"))
        await metronome.handle(stop)
        XCTAssertFalse(metronome.playing)
        _ = try await StartMetronomeIntent().perform()
        XCTAssertTrue(metronome.playing)

        try await simulateStoreEvent { try session.expireSubscription(productIdentifier: annualID) }
        try await waitForStoreEntitlements([])
        await metronome.subscription.refresh()
        XCTAssertFalse(metronome.playing)
        XCTAssertFalse(metronome.subscription.hasAccess)
    }

    @MainActor
    func testPresetsInsertReorderRenameLoadAndDelete() async throws {
        let session = try await freshStore()
        defer { session.clearTransactions() }

        let lifetimeID = MetronomeSubscription.lifetimeProductID
        try await session.buyProduct(identifier: lifetimeID)
        try await waitForStoreEntitlements([lifetimeID])
        let metronome = Metronome.shared
        try await metronome.subscription.verifyAccess()
        let original = metronome.settings
        let names = (UUID().uuidString, UUID().uuidString)
        defer {
            for preset in metronome.presets where [names.0, names.1, names.1 + "-renamed"].contains(preset.name) {
                metronome.deletePreset(preset.id)
            }
            try? metronome.update(original)
        }

        try metronome.setTempo(121)
        metronome.savePreset(named: names.0)
        try metronome.setTempo(143)
        metronome.savePreset(named: names.1)
        XCTAssertEqual(metronome.presets.prefix(2).map(\.name), [names.1, names.0])
        let newest = try XCTUnwrap(metronome.presets.first)
        metronome.movePresets(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(metronome.presets.prefix(2).map(\.name), [names.0, names.1])
        metronome.renamePreset(newest.id, to: names.1 + "-renamed")
        XCTAssertEqual(metronome.presets[1].name, names.1 + "-renamed")
        try metronome.setTempo(100)
        try metronome.loadPreset(metronome.presets[1])
        XCTAssertEqual(metronome.settings.bpm, 143)
        metronome.deletePreset(newest.id)
        XCTAssertFalse(metronome.presets.contains { $0.id == newest.id })
    }

    @MainActor
    func testAdvancedSettingsAndSiriActions() async throws {
        let session = try await freshStore()
        defer { session.clearTransactions() }

        let lifetimeID = MetronomeSubscription.lifetimeProductID
        try await session.buyProduct(identifier: lifetimeID)
        try await waitForStoreEntitlements([lifetimeID])
        let metronome = Metronome.shared
        try await metronome.subscription.verifyAccess()
        let original = metronome.settings
        let originalPreferences = metronome.preferences
        defer {
            try? metronome.changePreferences(originalPreferences)
            try? metronome.update(original)
        }

        try metronome.changePreferences(MetronomePreferences())
        XCTAssertThrowsError(try metronome.setTempo(20))
        XCTAssertThrowsError(try metronome.update(BeatSettings(beats: 32, unit: 64)))

        var advanced = MetronomePreferences()
        advanced.professionalTempo = true
        advanced.extendedMeter = true
        advanced.showTempoMark = true
        advanced.keepAwake = false
        advanced.mixWithOthers = false
        advanced.flash = true
        advanced.haptics = true
        advanced.volume = 0.75
        advanced.balance = -0.4
        advanced.offsetMilliseconds = 35
        advanced.trainer.enabled = true
        advanced.ghost.enabled = true
        try metronome.changePreferences(advanced)
        XCTAssertEqual(metronome.preferences, advanced)

        try metronome.update(BeatSettings(bpm: 300, beats: 32, unit: 64))
        XCTAssertEqual(metronome.settings.accents.count, 32)
        XCTAssertEqual(metronome.settings.tempoMark, "Presto")

        let query = SpokenMetronomeTempoQuery()
        let availableTempos = try await query.suggestedEntities()
        XCTAssertEqual(availableTempos.map(\.id), Array(20...300))
        let tempos = try await query.entities(for: [19, 20, 116, 300, 301])
        XCTAssertEqual(tempos.map(\.id), [20, 116, 300])

        var tempoAction = SetSpokenMetronomeTempoIntent()
        tempoAction.tempo = SpokenMetronomeTempo(id: 116)
        _ = try await tempoAction.perform()
        XCTAssertEqual(metronome.settings.bpm, 116)
        var meterAction = SetMetronomeMeterIntent()
        for option in MeterOption.allCases {
            meterAction.meter = option
            _ = try await meterAction.perform()
            XCTAssertEqual(metronome.settings.meter, option.rawValue)
        }
        var settings = metronome.settings
        settings.accents[0] = .strong
        try metronome.update(settings)
        for accent in [BeatAccent.medium, .weak, .silent, .strong] {
            try metronome.cycleAccent(0)
            XCTAssertEqual(metronome.settings.accents[0], accent)
        }
    }

    private struct StoreEntitlementsDidNotSettle: Error, CustomStringConvertible {
        let expected: Set<String>
        let actual: Set<String>

        var description: String {
            "StoreKit did not publish the expected entitlements: expected \(expected.sorted()), saw \(actual.sorted())"
        }
    }

    @MainActor
    private func waitForStoreEntitlements(_ expected: Set<String>) async throws {
        // StoreKitTest completes the operation before the simulated store propagates it.
        let deadline = ContinuousClock.now + .seconds(12)
        while true {
            var active: Set<String> = []
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result,
                      transaction.revocationDate == nil,
                      transaction.expirationDate.map({ $0 > .now }) ?? true else { continue }
                active.insert(transaction.productID)
            }
            if active == expected { return }
            guard ContinuousClock.now < deadline else {
                throw StoreEntitlementsDidNotSettle(expected: expected, actual: active)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    @MainActor
    private func simulateStoreEvent(_ operation: @escaping @Sendable () throws -> Void) async throws {
        try await Task.detached(operation: operation).value
    }

    @MainActor
    private func freshStore() async throws -> SKTestSession {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "MetronomeTestProducts", withExtension: "storekit"
        ))
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        try await waitForStoreEntitlements([])
        return session
    }

    @MainActor
    private func annualProduct() async throws -> Product {
        let products = try await Product.products(for: [MetronomeSubscription.annualProductID])
        return try XCTUnwrap(products.first)
    }
}

