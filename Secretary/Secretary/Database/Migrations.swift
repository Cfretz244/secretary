import GRDB

enum Migrations {
    static func register(in migrator: inout DatabaseMigrator) {
        // Initial schema is created directly via Schema.create
        // Future migrations go here:
        // migrator.registerMigration("v2") { db in ... }
    }
}
