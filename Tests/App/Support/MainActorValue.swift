/// A value that a test changes after a `@MainActor` closure captured it.
/// Such closures are `Sendable`, so a captured `var` that changes later
/// gets a compiler warning; a main-actor class does not.
@MainActor
final class MainActorValue<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
