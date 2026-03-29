import StoreKit
import SwiftUI
import Combine

// --- TIP STORE (In-App Purchase Manager) ---
@MainActor
class TipStore: ObservableObject {
    // This matches the ID in your App Store Connect
    private let productIds = ["unlockmodes299"]
    
    @Published var products: [Product] = []
    @Published var hasUnlockedPro = false
    
    // NEW: Task to listen for transactions (Promo Codes / Ask to Buy)
    private var updateListenerTask: Task<Void, Error>? = nil
    
    init() {
        // 1. Start the listener IMMEDIATELY.
        // This catches promo codes entered outside the app.
        updateListenerTask = listenForTransactions()
        
        #if DEBUG
        // --- DEVELOPER MODE (Xcode) ---
        print("DEBUG MODE: Auto-unlocking Pro features.")
        self.hasUnlockedPro = true
        
        // Load products for debugging
        Task { await loadProducts() }
        
        #else
        // --- PRODUCTION MODE (TestFlight / App Store) ---
        // 2. Check current status
        Task { await updateCustomerProductStatus() }
        
        // 3. Load product details
        Task { await loadProducts() }
        #endif
    }
    
    deinit {
        // Clean up the listener when the app/class dies
        updateListenerTask?.cancel()
    }
    
    // --- NEW: THE LISTENER FUNCTION ---
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            // Iterate through any transactions that update globally
            for await result in Transaction.updates {
                do {
                    // Use your existing helper to verify
                    let transaction = try self.checkVerified(result)
                    
                    // Update the UI
                    await self.updateCustomerProductStatus()
                    
                    // Always finish the transaction so it doesn't pop up again
                    await transaction.finish()
                } catch {
                    print("Transaction failed verification")
                }
            }
        }
    }
    
    func loadProducts() async {
        do {
            products = try await Product.products(for: productIds)
        } catch {
            print("Failed to load products: \(error)")
        }
    }
    
    func purchase(_ product: Product) async {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                // Update status immediately
                await updateCustomerProductStatus()
                
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            print("Purchase failed: \(error)")
        }
    }
    
    func updateCustomerProductStatus() async {
        // Iterate through all of the user's current entitlements
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)
                if productIds.contains(transaction.productID) {
                    // If we find a valid transaction for your ID, unlock it
                    // We must do this on MainActor (which the class is)
                    self.hasUnlockedPro = true
                }
            } catch {
                print("Verification failed")
            }
        }
    }
    
    // Helper to verify cryptographically
    // Moved outside or kept here, but it needs to be accessible to the detached task
    // Since checkVerified is pure logic, it's safer to make it non-isolated or static
    // BUT for simplicity, we can call it on self if we are careful about context.
    // The easiest fix for the detached task above is to make this non-actor-isolated:
    nonisolated func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
    
    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await updateCustomerProductStatus()
        } catch {
            print("Restore failed: \(error)")
        }
    }
}

enum StoreError: Error {
    case failedVerification
}
