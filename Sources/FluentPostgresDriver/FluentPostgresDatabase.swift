import FluentSQL

struct _FluentPostgresDatabase {
    let database: PostgresDatabase
    let context: DatabaseContext
    let encoder: PostgresDataEncoder
    let decoder: PostgresDataDecoder
    let inTransaction: Bool
}

extension _FluentPostgresDatabase: Database {
    func execute(
        query: DatabaseQuery,
        onOutput: @escaping (DatabaseOutput) -> ()
    ) -> EventLoopFuture<Void> {
        var expression = SQLQueryConverter(delegate: PostgresConverterDelegate())
            .convert(query)
        switch query.action {
        case .create:
            expression = PostgresReturningID(
                base: expression,
                idKey: query.customIDKey ?? .id
            )
        default: break
        }
        let (sql, binds) = self.serialize(expression)
        do {
            return try self.query(sql, binds.map { try self.encoder.encode($0) }) {
                onOutput($0.databaseOutput(using: self.decoder))
            }
        } catch {
            return self.eventLoop.makeFailedFuture(error)
        }
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        let expression = SQLSchemaConverter(delegate: PostgresConverterDelegate())
            .convert(schema)
        let (sql, binds) = self.serialize(expression)
        do {
            return try self.query(sql, binds.map { try self.encoder.encode($0) }) {
                fatalError("unexpected row: \($0)")
            }
        } catch {
            return self.eventLoop.makeFailedFuture(error)
        }
    }

    func execute(enum e: DatabaseEnum) -> EventLoopFuture<Void> {
        switch e.action {
        case .create:
            let builder = self.sql().create(enum: e.name)
            for c in e.createCases {
                _ = builder.value(c)
            }
            return builder.run()
        case .update:
            if !e.deleteCases.isEmpty {
                self.logger.error("PostgreSQL does not support deleting enum cases.")
            }
            guard !e.createCases.isEmpty else {
                return self.eventLoop.makeSucceededFuture(())
            }

            return database.eventLoop.flatten(e.createCases.map { create in
                sql()
                    .alter(enum: e.name)
                    .add(value: create)
                    .run()
            })
        case .delete:
            return self.sql().drop(enum: e.name).run()
        }
    }

    func transaction<T>(_ closure: @escaping (Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        guard !self.inTransaction else {
            return closure(self)
        }
        return self.database.withConnection { conn in
            conn.simpleQuery("BEGIN").flatMap { _ in
                let db = _FluentPostgresDatabase(
                    database: conn,
                    context: self.context,
                    encoder: self.encoder,
                    decoder: self.decoder,
                    inTransaction: true
                )
                return closure(db).flatMap { result in
                    conn.simpleQuery("COMMIT").map { _ in
                        result
                    }
                }.flatMapError { error in
                    conn.simpleQuery("ROLLBACK").flatMapThrowing { _ in
                        throw error
                    }
                }
            }
        }
    }
    
    func withConnection<T>(_ closure: @escaping (Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        self.database.withConnection {
            closure(_FluentPostgresDatabase(
                database: $0,
                context: self.context,
                encoder: self.encoder,
                decoder: self.decoder,
                inTransaction: self.inTransaction
            ))
        }
    }
}

extension _FluentPostgresDatabase: SQLDatabase {
    var dialect: SQLDialect {
        PostgresDialect()
    }
    
    public func execute(
        sql query: SQLExpression,
        _ onRow: @escaping (SQLRow) -> ()
    ) -> EventLoopFuture<Void> {
        self.sql(encoder: encoder, decoder: decoder).execute(sql: query, onRow)
    }
}

extension _FluentPostgresDatabase: PostgresDatabase {
    func send(_ request: PostgresRequest, logger: Logger) -> EventLoopFuture<Void> {
        self.database.send(request, logger: logger)
    }
    
    func withConnection<T>(_ closure: @escaping (PostgresConnection) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        self.database.withConnection(closure)
    }
}

private struct PostgresReturningID: SQLExpression {
    let base: SQLExpression
    let idKey: FieldKey

    func serialize(to serializer: inout SQLSerializer) {
        serializer.statement {
            $0.append(self.base)
            $0.append("RETURNING")
            $0.append(SQLIdentifier(self.idKey.description))
        }
    }
}
