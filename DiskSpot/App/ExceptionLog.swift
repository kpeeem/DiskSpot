#if DEBUG
import Foundation
import ObjectiveC

/// AppKit catches layout exceptions and aborts without printing the reason anywhere but the
/// (redacted) unified log, so the reason is written to stderr the moment an exception is made.
enum ExceptionLog {
    static func install() {
        typealias Initializer = @convention(c) (NSException, Selector, NSExceptionName, String?, [AnyHashable: Any]?) -> NSException
        let selector = NSSelectorFromString("initWithName:reason:userInfo:")
        guard let method = class_getInstanceMethod(NSException.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let block: @convention(block) (NSException, NSExceptionName, String?, [AnyHashable: Any]?) -> NSException = { object, name, reason, info in
            let text = "NSException \(name.rawValue): \(reason ?? "")\n" + Thread.callStackSymbols.prefix(40).joined(separator: "\n") + "\n"
            FileHandle.standardError.write(text.data(using: .utf8)!)
            return original(object, selector, name, reason, info)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
#endif
