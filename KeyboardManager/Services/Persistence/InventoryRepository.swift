import Foundation

protocol InventoryRepository: Sendable {
    func loadSnapshot() async throws -> InventorySnapshot
    func saveSnapshot(_ snapshot: InventorySnapshot) async throws
}

actor InMemoryInventoryRepository: InventoryRepository {
    private var snapshot: InventorySnapshot

    init(snapshot: InventorySnapshot = .empty) {
        self.snapshot = snapshot
    }

    func loadSnapshot() async throws -> InventorySnapshot {
        snapshot
    }

    func saveSnapshot(_ snapshot: InventorySnapshot) async throws {
        self.snapshot = snapshot
    }
}
