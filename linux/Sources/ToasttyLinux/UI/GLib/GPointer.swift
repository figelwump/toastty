import CGtk
import CGtkShim

/// GTK imports widget types two ways: types with a public instance struct
/// (`GtkWidget`, `GtkBox`, `GtkWindow`) arrive as `UnsafeMutablePointer<T>`,
/// and final/private types (`GtkPaned`, `GtkLabel`, every `Adw*`) arrive as
/// `OpaquePointer`. `GPointer` unifies both so call sites can write
/// `gtk_paned_set_start_child(cast(paned), cast(child))` and let the
/// expected parameter type pick the conversion.
public protocol GPointer {
    var rawGPointer: UnsafeMutableRawPointer { get }
}

extension UnsafeMutablePointer: GPointer {
    public var rawGPointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

extension OpaquePointer: GPointer {
    public var rawGPointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

extension UnsafeMutableRawPointer: GPointer {
    public var rawGPointer: UnsafeMutableRawPointer { self }
}

public typealias WidgetPtr = UnsafeMutablePointer<GtkWidget>

/// Reinterprets a GObject pointer as a typed instance pointer. The caller is
/// responsible for the instance actually being of that type; use
/// `isInstance(_:of:)` when it is not statically known.
@inline(__always)
public func cast<T>(_ pointer: some GPointer) -> UnsafeMutablePointer<T> {
    pointer.rawGPointer.assumingMemoryBound(to: T.self)
}

@inline(__always)
public func cast(_ pointer: some GPointer) -> OpaquePointer {
    OpaquePointer(pointer.rawGPointer)
}

@inline(__always)
public func widget(_ pointer: some GPointer) -> WidgetPtr {
    pointer.rawGPointer.assumingMemoryBound(to: GtkWidget.self)
}

/// `G_TYPE_CHECK_INSTANCE_TYPE`.
@inline(__always)
public func isInstance(_ pointer: (some GPointer)?, of type: GType) -> Bool {
    guard let pointer else { return false }
    return toastty_instance_is_a(pointer.rawGPointer, type) != 0
}

public func typeName(_ pointer: (some GPointer)?) -> String {
    guard let pointer else { return "(null)" }
    return String(cString: toastty_object_type_name(pointer.rawGPointer))
}

/// Strong reference to a GObject. Sinks floating references, so a widget
/// held here survives being unparented and re-parented (split-tree rebuilds
/// move terminal widgets between `GtkPaned`s without recreating them).
public final class GObjectRef: @unchecked Sendable, Hashable {
    public let pointer: UnsafeMutableRawPointer

    public init(sinking pointer: some GPointer) {
        self.pointer = pointer.rawGPointer
        g_object_ref_sink(self.pointer)
    }

    /// Adopts an already-owned (full transfer) reference without adding one.
    public init(adopting pointer: some GPointer) {
        self.pointer = pointer.rawGPointer
    }

    deinit {
        g_object_unref(pointer)
    }

    public var widgetPointer: WidgetPtr { widget(pointer) }

    public static func == (lhs: GObjectRef, rhs: GObjectRef) -> Bool { lhs.pointer == rhs.pointer }
    public func hash(into hasher: inout Hasher) { hasher.combine(pointer) }
}

extension Bool {
    @inline(__always) public var gboolean: gboolean { self ? 1 : 0 }
}

extension gboolean {
    @inline(__always) public var bool: Bool { self != 0 }
}

/// Builds a `GVariant` string; floating, so it can be passed straight to
/// action activation.
public func variantString(_ value: String) -> OpaquePointer {
    g_variant_new_string(value)
}

public func variantStringValue(_ variant: OpaquePointer?) -> String? {
    guard let variant else { return nil }
    guard g_variant_is_of_type(variant, g_variant_type_checked_("s")).bool else { return nil }
    return String(cString: g_variant_get_string(variant, nil))
}
