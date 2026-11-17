import CGtk
import CGtkShim

/// Typed GObject property access (`g_object_get`/`set` are variadic and
/// unavailable to Swift).
@MainActor
public enum GProperty {
    public static func int(_ object: some GPointer, _ name: String) -> Int32 {
        var value = GValue()
        g_value_init(&value, toastty_g_type_int())
        g_object_get_property(object.rawGPointer.assumingMemoryBound(to: GObject.self), name, &value)
        let result = g_value_get_int(&value)
        g_value_unset(&value)
        return result
    }

    public static func bool(_ object: some GPointer, _ name: String) -> Bool {
        var value = GValue()
        g_value_init(&value, toastty_g_type_boolean())
        g_object_get_property(object.rawGPointer.assumingMemoryBound(to: GObject.self), name, &value)
        let result = g_value_get_boolean(&value).bool
        g_value_unset(&value)
        return result
    }

    public static func setBool(_ object: some GPointer, _ name: String, _ newValue: Bool) {
        var value = GValue()
        g_value_init(&value, toastty_g_type_boolean())
        g_value_set_boolean(&value, newValue.gboolean)
        g_object_set_property(object.rawGPointer.assumingMemoryBound(to: GObject.self), name, &value)
        g_value_unset(&value)
    }

    public static func setString(_ object: some GPointer, _ name: String, _ newValue: String) {
        var value = GValue()
        g_value_init(&value, toastty_g_type_string())
        g_value_set_string(&value, newValue)
        g_object_set_property(object.rawGPointer.assumingMemoryBound(to: GObject.self), name, &value)
        g_value_unset(&value)
    }
}
