import Foundation

// The Keychain status names shared code and tests use. Linux has no
// Keychain; `import Security` is dropped by the mirror.

public typealias OSStatus = Int32

/// `errSecInteractionNotAllowed`: the Keychain is locked.
public let errSecInteractionNotAllowed: OSStatus = -25308
