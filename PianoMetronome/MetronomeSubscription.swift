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

    @Published private var access: Access = .checking {
        didSet {
            if oldValue != access { onAccessChanged?(hasAccess) }
        }
    }
    var onAccessChanged: ((Bool) -> Void)?

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

    var ownsLifetime: Bool { access == .lifetime }
    var hasActiveSubscription: Bool {
        guard case .active(let expiration) = access else { return false }
        return expiration > .now
    }

    var hasAccess: Bool {
        #if targetEnvironment(simulator)
        if isLayoutPreview { return true }
        #endif
        return switch access {
        case .lifetime: true
        case .active(let expiration): expiration > .now
        case .checking, .locked: false
        }
    }

    func purchaseMessage(for product: Product, using purchase: PurchaseAction) async -> String? {
        do {
            switch try await purchase(product) {
            case .success(let result):
                if await accept(result) { return nil }
                return String(localized: "无法验证这笔购买。请稍后恢复购买。")
            case .pending:
                return String(localized: "购买正在等待 Apple 确认。完成后将自动解锁。")
            case .userCancelled:
                return nil
            @unknown default:
                return String(localized: "暂时无法确认购买状态。请稍后恢复购买。")
            }
        } catch {
            return error.localizedDescription
        }
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
            if access != .locked { access = .locked }
            return
        }

        let next = Access.active(until: latestExpiration)
        if access != next { access = next }
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
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss
    @State private var lifetime: Product?
    @State private var loading = true
    @State private var busy = false
    @State private var showingManagement = false
    @State private var showingRedemption = false
    @State private var showingPrivacy = false
    @State private var confirmingBuyout = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("解锁全部拍号和音色")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                if loading {
                    ProgressView("正在加载价格…")
                } else if let lifetime {
                    purchaseOption(lifetime)
                } else {
                    Button("重新加载价格") { Task { await loadProducts() } }
                        .disabled(busy)
                }

                accountActions
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(MetronomePalette.background)
        .tint(MetronomePalette.cyan)
        .task {
            await subscription.refresh()
            guard !Task.isCancelled else { return }
            if subscription.ownsLifetime { dismiss() } else { await loadProducts() }
        }
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
            if ownsLifetime { dismiss() }
        }
    }

    private func purchaseOption(_ product: Product) -> some View {
        Button {
            if subscription.hasActiveSubscription {
                confirmingBuyout = true
            } else {
                Task { await buy(product) }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("一次性买断").font(.headline)
                    Text("一次支付 \(product.displayPrice)，永久解锁全部功能。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MetronomePalette.cyan)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 68)
            .background(MetronomePalette.track, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var accountActions: some View {
        VStack(spacing: 0) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { purchaseSupportActions.fixedSize() }
                VStack(spacing: 0) { purchaseSupportActions }
            }

            HStack(spacing: 18) {
                Link("使用条款", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Button("隐私政策") { showingPrivacy = true }
            }
            .frame(minHeight: 44)
        }
        .font(.footnote)
        .tint(.secondary)
        .disabled(busy)
    }

    @ViewBuilder
    private var purchaseSupportActions: some View {
        Button("恢复购买") { Task { await restorePurchases() } }.frame(minHeight: 44)
        Button("兑换优惠码") { showingRedemption = true }.frame(minHeight: 44)
        if subscription.hasActiveSubscription {
            Button("管理订阅") { showingManagement = true }.frame(minHeight: 44)
        }
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
        do {
            let products = try await Product.products(for: [MetronomeSubscription.lifetimeProductID])
            guard !Task.isCancelled else { return }
            lifetime = products.first { $0.id == MetronomeSubscription.lifetimeProductID && $0.type == .nonConsumable }
        } catch {
            if !Task.isCancelled && lifetime == nil { message = error.localizedDescription }
        }
    }

    private func refreshStore() async {
        await subscription.refresh()
        if !subscription.ownsLifetime && lifetime == nil { await loadProducts() }
    }

    private func buy(_ product: Product) async {
        guard !busy, !subscription.ownsLifetime else { return }
        busy = true
        defer { busy = false }
        message = await subscription.purchaseMessage(for: product, using: purchase)
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

@MainActor
struct MetronomePurchaseSheet: View {
    let subscription: MetronomeSubscription
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MetronomeSubscriptionView(subscription: subscription)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { dismiss() }
                    }
                }
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
