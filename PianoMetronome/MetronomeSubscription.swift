import Foundation
import StoreKit
import SwiftUI

@MainActor
final class MetronomeSubscription: ObservableObject {
    static let annualProductID = "com.bytereset.metronome.annual"
    static let lifetimeProductID = "com.bytereset.metronome.lifetime"

    // Keep recognizing transactions from TestFlight builds that offered the original products.
    private static let annualEntitlementIDs: Set<String> = [annualProductID, "app.music.metronome.annual"]
    private static let lifetimeEntitlementIDs: Set<String> = [lifetimeProductID, "app.music.metronome.lifetime"]

    private enum Access: Equatable {
        case checking, locked, active(until: Date), lifetime
    }

    @Published private var access: Access = .checking
    @Published private var testingSession = false
    @Published private(set) var canContinueTesting = false
    var onAccessLost: (() -> Void)?

    private var refreshTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?

    #if targetEnvironment(simulator)
    private let isLayoutPreview = ProcessInfo.processInfo.arguments.contains("--metronome-layout-preview")
    #endif

    init() {
        Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                _ = await accept(result)
            }
        }
    }

    var isChecking: Bool { access == .checking }
    var ownsLifetime: Bool { access == .lifetime }

    var hasAccess: Bool {
        #if targetEnvironment(simulator)
        if isLayoutPreview { return true }
        #endif
        if testingSession { return true }
        return switch access {
        case .lifetime: true
        case .active(let expiration): expiration > .now
        case .checking, .locked: false
        }
    }

    func checkTestBuild() async {
        guard !canContinueTesting, let result = try? await AppTransaction.shared,
              case .verified(let transaction) = result,
              transaction.bundleID == Bundle.main.bundleIdentifier,
              transaction.environment == .sandbox else { return }
        canContinueTesting = true
    }

    func continueTesting() {
        guard canContinueTesting, access == .locked else { return }
        testingSession = true
    }

    func requireAccess() throws {
        guard hasAccess else { throw MetronomeError.subscriptionRequired }
    }

    func verifyAccess() async throws {
        await refresh()
        try requireAccess()
    }

    func accept(_ result: VerificationResult<StoreKit.Transaction>) async -> Bool {
        guard case .verified(let transaction) = result else { return false }
        switch (transaction.productID, transaction.productType) {
        case (let id, .autoRenewable) where Self.annualEntitlementIDs.contains(id),
             (let id, .nonConsumable) where Self.lifetimeEntitlementIDs.contains(id):
            await refresh()
            await transaction.finish()
            return true
        default:
            return false
        }
    }

    func refresh() async {
        #if targetEnvironment(simulator)
        guard !isLayoutPreview else { return }
        #endif
        // Read snapshots in order so a pre-purchase refresh cannot overwrite a later one.
        let previous = refreshTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.readEntitlement()
        }
        refreshTask = task
        await task.value
    }

    private func readEntitlement() async {
        var latestExpiration: Date?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil else { continue }
            if Self.lifetimeEntitlementIDs.contains(transaction.productID), transaction.productType == .nonConsumable {
                expirationTask?.cancel()
                expirationTask = nil
                if !ownsLifetime { access = .lifetime }
                if testingSession { testingSession = false }
                return
            }
            guard Self.annualEntitlementIDs.contains(transaction.productID),
                  transaction.productType == .autoRenewable,
                  !transaction.isUpgraded,
                  let expiration = transaction.expirationDate else { continue }
            latestExpiration = max(latestExpiration ?? expiration, expiration)
        }

        expirationTask?.cancel()
        expirationTask = nil
        guard let latestExpiration, latestExpiration > .now else {
            if access != .locked {
                if !testingSession { onAccessLost?() }
                access = .locked
            }
            return
        }

        let next = Access.active(until: latestExpiration)
        if access != next { access = next }
        if testingSession { testingSession = false }
        expirationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, latestExpiration.timeIntervalSinceNow)))
            } catch {
                return
            }
            await self?.refresh()
        }
    }
}

@MainActor
struct MetronomeSubscriptionView: View {
    @ObservedObject var subscription: MetronomeSubscription
    var buyoutOnly = false
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss
    @State private var products: [Product] = []
    @State private var showsFreeTrial = false
    @State private var loading = true
    @State private var busy = false
    @State private var showingManagement = false
    @State private var showingRedemption = false
    @State private var showingPrivacy = false
    @State private var confirmingBuyout = false
    @State private var message: String?

    private var annual: Product? {
        products.first {
            guard $0.id == MetronomeSubscription.annualProductID,
                  $0.type == .autoRenewable,
                  let period = $0.subscription?.subscriptionPeriod else { return false }
            return period.unit == .year && period.value == 1
        }
    }

    private var lifetime: Product? {
        products.first { $0.id == MetronomeSubscription.lifetimeProductID && $0.type == .nonConsumable }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("解锁全部功能")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)

                if !buyoutOnly {
                    purchaseCard("年度订阅", price: annual.map { String(localized: "\($0.displayPrice) / 年") }) {
                        Text(showsFreeTrial
                             ? LocalizedStringKey("免费试用 7 天，之后按上方年费自动续订。如不想续订，请在试用结束至少 24 小时前取消。")
                             : LocalizedStringKey("按年自动续订，可在 App Store 管理或取消。"))
                        if let annual {
                            purchaseButton(showsFreeTrial ? LocalizedStringKey("开始 7 天免费试用") : LocalizedStringKey("订阅一年")) {
                                Task { await buy(annual) }
                            }
                        }
                    }
                }

                purchaseCard("一次性买断", price: lifetime?.displayPrice) {
                    Text("一次付款，永久解锁本 App 的全部节拍器功能。")
                    if let lifetime {
                        purchaseButton("立即买断") {
                            if buyoutOnly && subscription.hasAccess {
                                confirmingBuyout = true
                            } else {
                                Task { await buy(lifetime) }
                            }
                        }
                    }
                }

                if loading {
                    ProgressView("正在加载价格…")
                } else if lifetime == nil || (!buyoutOnly && annual == nil) {
                    Button("重新加载价格") { Task { await loadProducts() } }
                        .disabled(busy)
                }

                if !buyoutOnly && !loading && annual == nil && subscription.canContinueTesting {
                    purchaseButton("继续测试") { subscription.continueTesting() }
                    Text("仅本次启动有效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                accountActions
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .task { await loadProducts() }
        .manageSubscriptionsSheet(isPresented: $showingManagement)
        .onChange(of: showingManagement) { _, isShowing in
            if !isShowing { Task { await refreshStore() } }
        }
        .offerCodeRedemption(isPresented: $showingRedemption) { result in
            switch result {
            case .success: Task { await refreshStore() }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .confirmationDialog("改为一次性买断", isPresented: $confirmingBuyout, titleVisibility: .visible) {
            Button("继续买断") {
                if let lifetime { Task { await buy(lifetime) } }
            }
            Button("管理订阅") { showingManagement = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("买断不会关闭原订阅的自动续订。如果续订仍开启，请在「管理订阅」中关闭，以免下次扣费。")
        }
        .alert("App Store", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .sheet(isPresented: $showingPrivacy) { privacyPolicy }
        .onChange(of: subscription.ownsLifetime) { _, ownsLifetime in
            if buyoutOnly && ownsLifetime { dismiss() }
        }
    }

    private func purchaseCard<Content: View>(
        _ title: LocalizedStringKey, price: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if let price {
                Text(price).font(.title2.bold())
            } else if !loading {
                Text("暂时无法获取价格").foregroundStyle(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func purchaseButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy)
    }

    @ViewBuilder
    private var accountActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("恢复购买") { Task { await restorePurchases() } }
            Button("兑换优惠码") { showingRedemption = true }
            Button("管理订阅") { showingManagement = true }
            Link("使用条款", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            Button("隐私政策") { showingPrivacy = true }
        }
        .disabled(busy)
    }

    private var privacyPolicy: some View {
        NavigationStack {
            MetronomePrivacyPolicyView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showingPrivacy = false }
                    }
                }
        }
    }

    private func loadProducts() async {
        loading = true
        defer { loading = false }
        let ids = buyoutOnly
            ? [MetronomeSubscription.lifetimeProductID]
            : [MetronomeSubscription.annualProductID, MetronomeSubscription.lifetimeProductID]
        do {
            let availableProducts = try await Product.products(for: ids)
            guard !Task.isCancelled else { return }
            if let plan = availableProducts.first(where: { $0.id == MetronomeSubscription.annualProductID })?.subscription,
               let offer = plan.introductoryOffer, offer.paymentMode == .freeTrial,
               offer.periodCount == 1,
               (offer.period.unit == .week && offer.period.value == 1)
               || (offer.period.unit == .day && offer.period.value == 7) {
                showsFreeTrial = await plan.isEligibleForIntroOffer
            } else {
                showsFreeTrial = false
            }
            guard !Task.isCancelled else { return }
            products = availableProducts
        } catch {
            if !Task.isCancelled && products.isEmpty { message = error.localizedDescription }
        }
        if !Task.isCancelled && !buyoutOnly && annual == nil {
            await subscription.checkTestBuild()
        }
    }

    private func refreshStore() async {
        await subscription.refresh()
        if !subscription.hasAccess { await loadProducts() }
    }

    private func buy(_ product: Product) async {
        guard !busy, !subscription.ownsLifetime,
              product.id != MetronomeSubscription.annualProductID || !subscription.hasAccess else { return }
        busy = true
        defer { busy = false }
        do {
            switch try await purchase(product) {
            case .success(let result):
                let verified = await subscription.accept(result)
                if !verified {
                    message = String(localized: "无法验证这笔购买。请稍后恢复购买。")
                }
            case .pending:
                message = String(localized: "购买正在等待 Apple 确认。完成后将自动解锁。")
            case .userCancelled:
                return
            @unknown default:
                message = String(localized: "暂时无法确认购买状态。请稍后恢复购买。")
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func restorePurchases() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refreshStore()
            if !subscription.hasAccess { message = String(localized: "未找到有效的节拍器订阅或买断记录。") }
        } catch {
            message = error.localizedDescription
        }
    }
}

struct MetronomePrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            Text("节拍器无需注册账户。节拍设置和曲目预设存储在设备上。购买和订阅由 Apple 处理，节拍器通过 StoreKit 确认购买权益。")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("隐私政策")
    }
}
