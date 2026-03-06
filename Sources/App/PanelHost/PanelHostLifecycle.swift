import AppKit
import Foundation

struct PanelHostAttachmentToken: Equatable, Hashable, Sendable {
    let generation: UInt64
    let rawValue: UUID

    private init(generation: UInt64, rawValue: UUID = UUID()) {
        self.generation = generation
        self.rawValue = rawValue
    }

    @MainActor
    static func next() -> PanelHostAttachmentToken {
        generationCounter &+= 1
        return PanelHostAttachmentToken(generation: generationCounter)
    }

    @MainActor
    private static var generationCounter: UInt64 = 0
}

enum PanelHostLifecycleState: Equatable, Sendable {
    case detached
    case attached(PanelHostAttachmentToken)
    case ready(PanelHostAttachmentToken)

    var attachmentToken: PanelHostAttachmentToken? {
        switch self {
        case .detached:
            return nil
        case .attached(let token), .ready(let token):
            return token
        }
    }

    var isReadyForFocus: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    var automationLabel: String {
        switch self {
        case .detached:
            return "detached"
        case .attached:
            return "attached"
        case .ready:
            return "ready"
        }
    }
}

@MainActor
protocol PanelHostLifecycleControlling: AnyObject {
    var lifecycleState: PanelHostLifecycleState { get }
    func attachHost(to container: NSView, attachment: PanelHostAttachmentToken)
    func detachHost(attachment: PanelHostAttachmentToken)
}

@MainActor
final class PanelHostContainerCoordinator {
    private weak var activeContainer: NSView?
    private weak var lifecycleController: (any PanelHostLifecycleControlling)?
    private(set) var activeAttachment: PanelHostAttachmentToken?

    func attachment(
        for container: NSView,
        controller: any PanelHostLifecycleControlling
    ) -> PanelHostAttachmentToken {
        let controllerChanged = lifecycleController.map(ObjectIdentifier.init) != ObjectIdentifier(controller)
        if activeContainer !== container || controllerChanged || activeAttachment == nil {
            reset()
            activeContainer = container
            lifecycleController = controller
            activeAttachment = PanelHostAttachmentToken.next()
        }
        return activeAttachment!
    }

    func reset() {
        if let lifecycleController, let activeAttachment {
            lifecycleController.detachHost(attachment: activeAttachment)
        }
        activeContainer = nil
        lifecycleController = nil
        activeAttachment = nil
    }
}
