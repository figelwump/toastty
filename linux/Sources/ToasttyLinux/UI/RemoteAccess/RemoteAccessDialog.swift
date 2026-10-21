#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CoreState
import Foundation
import RemoteProtocol
import ToasttyAppLogic

/// Remote Access window (macOS `RemoteAccessSettingsView`): enable switch,
/// connection status, Tailscale Serve setup and tailnet origin, the pairing
/// QR code with its fallback code and expiry, and paired devices with
/// revoke. Reads `LinuxAppLogic.remoteAccessStatus`, polling while open (the
/// status is a value; rows rebuild only when it changes).
@MainActor
public final class RemoteAccessDialog {
    public let dialog: WidgetPtr
    private let ref: GObjectRef
    private let logic: LinuxAppLogic
    private let page: WidgetPtr
    private var groups: [WidgetPtr] = []
    private var lastStatus: LinuxRemoteAccessStatus?
    private var lastSecond = -1
    private var timer: guint = 0
    private var originEntry: WidgetPtr?
    /// The open dialog. Held strongly while presented: the status poll
    /// stops once the dialog is released.
    public private(set) static var current: RemoteAccessDialog?

    public init(logic: LinuxAppLogic) {
        self.logic = logic
        dialog = widget(adw_dialog_new()!)
        ref = GObjectRef(sinking: dialog)
        adw_dialog_set_title(cast(dialog), "Remote Access")
        adw_dialog_set_content_width(cast(dialog), 520)
        adw_dialog_set_content_height(cast(dialog), 640)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(toolbar), adw_header_bar_new())
        page = adw_preferences_page_new()!
        adw_toolbar_view_set_content(cast(toolbar), page)
        adw_dialog_set_child(cast(dialog), toolbar)
        Signal.connect(dialog, "closed") { [weak self] in
            guard let self else { return }
            MainLoop.cancel(self.timer)
            self.timer = 0
            if Self.current === self { Self.current = nil }
        }
        render(force: true)
        timer = MainLoop.timeout(milliseconds: 500) { [weak self] in
            self?.render(force: false)
            return self != nil
        }
    }

    public func present(over parent: WidgetPtr) {
        Self.current = self
        adw_dialog_present(cast(dialog), parent)
    }

    // MARK: Rendering

    private func render(force: Bool) {
        guard let status = logic.remoteAccessStatus else {
            if force { showUnavailable() }
            return
        }
        let second = status.pairingExpiresAt.map { Int($0.timeIntervalSinceNow) } ?? -1
        guard force || status != lastStatus || second != lastSecond else { return }
        // Do not rebuild under the user while they type a tailnet origin.
        if force == false, let originEntry, gtk_widget_get_root(originEntry) != nil,
           let focus = gtk_root_get_focus(gtk_widget_get_root(originEntry)), gtk_widget_is_ancestor(focus, originEntry).bool {
            return
        }
        lastStatus = status
        lastSecond = second
        for group in groups { adw_preferences_page_remove(cast(page), cast(group)) }
        groups = [gatewayGroup(status), devicesGroup(status)]
        if status.isReady { groups.insert(pairingGroup(status), at: 1) }
        for group in groups { adw_preferences_page_add(cast(page), cast(group)) }
    }

    private func showUnavailable() {
        let group = Self.group("Remote Access", "Remote Access is turned off for this instance (automation or test run).")
        groups = [group]
        adw_preferences_page_add(cast(page), cast(group))
    }

    private func gatewayGroup(_ status: LinuxRemoteAccessStatus) -> WidgetPtr {
        let group = Self.group("Gateway", "Follow and answer agent sessions from the Toastty iOS app over Tailscale.")
        let enable = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(enable), "Enable Remote Access")
        adw_switch_row_set_active(cast(enable), status.isEnabled.gboolean)
        Signal.notify(enable, "active") { [weak self] in
            self?.logic.setRemoteAccessEnabled(adw_switch_row_get_active(cast(enable)).bool)
        }
        adw_preferences_group_add(cast(group), enable)

        let state = adw_action_row_new()!
        adw_preferences_row_set_title(cast(state), status.title)
        adw_action_row_set_subtitle(cast(state), status.detail)
        let indicator = Gtk.image(Self.icon(for: status.indicator), pixelSize: 16, classes: [Self.cssClass(for: status.indicator)])
        if status.indicator == .progress {
            let spinner = adw_spinner_new()!
            adw_action_row_add_prefix(cast(state), spinner)
        } else {
            adw_action_row_add_prefix(cast(state), indicator)
        }
        Gtk.setName(state, "remote-access-status")
        adw_preferences_group_add(cast(group), state)

        if status.isEnabled {
            let clients = adw_action_row_new()!
            adw_preferences_row_set_title(cast(clients), "Connected Clients")
            adw_action_row_set_subtitle(cast(clients), status.connectedClientCount == 1 ? "1 client" : "\(status.connectedClientCount) clients")
            if let port = status.port {
                adw_action_row_add_suffix(cast(clients), Gtk.label("Port \(port)", classes: ["dim-label"]))
            }
            adw_preferences_group_add(cast(group), clients)

            let push = adw_action_row_new()!
            adw_preferences_row_set_title(cast(push), "Push Notifications")
            adw_action_row_set_subtitle(
                cast(push),
                status.isPushRelayConfigured
                    ? "Push relay configured"
                    : "No push relay configured (TOASTTY_PUSH_RELAY_URL)"
            )
            Gtk.setName(push, "remote-access-push")
            adw_preferences_group_add(cast(group), push)

            let origin = adw_entry_row_new()!
            adw_preferences_row_set_title(cast(origin), "Tailnet Origin")
            gtk_editable_set_text(cast(origin), status.tailnetOrigin)
            adw_entry_row_set_show_apply_button(cast(origin), 1)
            Signal.connect(origin, "apply") { [weak self] in
                self?.logic.setRemoteAccessTailnetOrigin(String(cString: gtk_editable_get_text(cast(origin))))
            }
            originEntry = origin
            adw_preferences_group_add(cast(group), origin)

            if status.isReady == false || status.indicator == .failure {
                let setup = adw_button_row_new()!
                adw_preferences_row_set_title(cast(setup), "Set Up Tailscale Serve")
                adw_button_row_set_start_icon_name(cast(setup), "view-refresh-symbolic")
                Signal.connect(setup, "activated") { [weak self] in self?.logic.retryRemoteAccessTailnetSetup() }
                adw_preferences_group_add(cast(group), setup)
            }
        }
        return group
    }

    private func pairingGroup(_ status: LinuxRemoteAccessStatus) -> WidgetPtr {
        let group = Self.group("Pair a Device", "Scan the code with the Toastty iOS app on the same tailnet.")
        if let error = status.pairingError {
            let row = adw_action_row_new()!
            adw_preferences_row_set_title(cast(row), "Pairing failed")
            adw_action_row_set_subtitle(cast(row), error)
            adw_action_row_add_prefix(cast(row), Gtk.image("dialog-error-symbolic", classes: ["error"]))
            adw_preferences_group_add(cast(group), row)
        }
        if let code = status.pairingFallbackCode {
            let box = Gtk.vbox(spacing: 10, classes: ["remote-access-pairing"])
            Gtk.margins(box, 12)
            if let png = logic.remoteAccessPairingQRCodePNG, let picture = Self.picture(png: png) {
                gtk_widget_set_size_request(picture, 240, 240)
                gtk_widget_set_halign(picture, GTK_ALIGN_CENTER)
                Gtk.setName(picture, "remote-access-qr")
                Gtk.append(box, picture)
            }
            let codeLabel = Gtk.label(code, classes: ["title-2", "monospace"], xalign: 0.5, ellipsize: false)
            gtk_label_set_selectable(cast(codeLabel), 1)
            Gtk.append(box, codeLabel)
            if let expires = status.pairingExpiresAt {
                let remaining = max(0, Int(expires.timeIntervalSinceNow))
                Gtk.append(box, Gtk.label("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))", classes: ["dim-label"], xalign: 0.5))
            }
            let buttons = Gtk.hbox(spacing: 8)
            gtk_widget_set_halign(buttons, GTK_ALIGN_CENTER)
            let copy = Gtk.button("Copy Code", classes: ["pill"])
            Signal.connect(copy, "clicked") { DesktopLauncher.copyToClipboard(code) }
            let cancel = Gtk.button("Cancel", classes: ["pill"])
            Signal.connect(cancel, "clicked") { [weak self] in self?.logic.cancelRemoteAccessPairingOffer() }
            Gtk.append(buttons, copy)
            Gtk.append(buttons, cancel)
            Gtk.append(box, buttons)
            adw_preferences_group_add(cast(group), box)
        } else {
            let pair = adw_button_row_new()!
            adw_preferences_row_set_title(cast(pair), "Show Pairing Code")
            adw_button_row_set_start_icon_name(cast(pair), "phone-symbolic")
            gtk_widget_set_sensitive(pair, status.canIssuePairingOffer.gboolean)
            Signal.connect(pair, "activated") { [weak self] in self?.logic.issueRemoteAccessPairingOffer() }
            adw_preferences_group_add(cast(group), pair)
        }
        return group
    }

    private func devicesGroup(_ status: LinuxRemoteAccessStatus) -> WidgetPtr {
        let devices = status.devices.filter { $0.isRevoked == false }
        let group = Self.group("Paired Devices", devices.isEmpty ? "No devices are paired." : nil)
        for device in devices {
            let row = adw_action_row_new()!
            adw_preferences_row_set_title(cast(row), device.name)
            let seen = device.lastSeenAt.map { "Last seen \(Self.relative($0))" } ?? "Never connected"
            adw_action_row_set_subtitle(cast(row), "\(device.authKind == .native ? "iOS app" : "Browser") · \(seen)")
            let revoke = Gtk.button("Revoke", classes: ["destructive-action", "flat"])
            gtk_widget_set_valign(revoke, GTK_ALIGN_CENTER)
            let id = device.id
            Signal.connect(revoke, "clicked") { [weak self] in self?.logic.revokeRemoteAccessDevice(id) }
            adw_action_row_add_suffix(cast(row), revoke)
            adw_preferences_group_add(cast(group), row)
        }
        if devices.count > 1 {
            let all = adw_button_row_new()!
            adw_preferences_row_set_title(cast(all), "Revoke All Devices")
            Gtk.addClasses(all, ["destructive-action"])
            Signal.connect(all, "activated") { [weak self] in
                guard let self else { return }
                Dialogs.confirm(parent: self.dialog, heading: "Revoke All Devices?", body: "Every paired device must pair again.", confirmLabel: "_Revoke All") { [weak self] in
                    self?.logic.revokeAllRemoteAccessDevices()
                }
            }
            adw_preferences_group_add(cast(group), all)
        }
        return group
    }

    // MARK: Helpers

    /// "just now", "5 min ago", "3 h ago", "2 d ago".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86_400) d ago"
    }

    static func group(_ title: String, _ description: String?) -> WidgetPtr {
        let group = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(group), title)
        if let description { adw_preferences_group_set_description(cast(group), description) }
        return group
    }

    static func icon(for indicator: LinuxRemoteAccessStatus.Indicator) -> String {
        switch indicator {
        case .off: return "network-offline-symbolic"
        case .progress: return "content-loading-symbolic"
        case .ready: return "object-select-symbolic"
        case .failure: return "dialog-warning-symbolic"
        }
    }

    static func cssClass(for indicator: LinuxRemoteAccessStatus.Indicator) -> String {
        switch indicator {
        case .off: return "dim-label"
        case .progress: return "accent"
        case .ready: return "success"
        case .failure: return "warning"
        }
    }

    /// A `GtkPicture` for PNG bytes (nearest-neighbor so QR modules stay crisp).
    static func picture(png: Data) -> WidgetPtr? {
        let bytes = png.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }!
        defer { g_bytes_unref(bytes) }
        var error: UnsafeMutablePointer<GError>?
        guard let texture = gdk_texture_new_from_bytes(bytes, &error) else {
            if let error { g_error_free(error) }
            return nil
        }
        let picture = gtk_picture_new_for_paintable(cast(texture))!
        g_object_unref(UnsafeMutableRawPointer(texture))
        gtk_picture_set_content_fit(cast(picture), GTK_CONTENT_FIT_CONTAIN)
        return picture
    }
}

/// Opens the Remote Access window for `app.remote-access.open` and backs the
/// Preferences "Remote Access" page.
@MainActor
public final class RemoteAccessCommands: WindowCommandHandling {
    private let logic: LinuxAppLogic
    public init(logic: LinuxAppLogic) { self.logic = logic }

    public func perform(commandID: String, windowID: UUID, window: WidgetPtr) -> Bool {
        guard commandID == "app.remote-access.open" else { return false }
        RemoteAccessDialog(logic: logic).present(over: window)
        return true
    }
}

extension LinuxAppController {
    /// Installs the Remote Access window command and Preferences page.
    public func installRemoteAccessUI(logic: LinuxAppLogic) {
        hosts.windowCommandHandlers.append(RemoteAccessCommands(logic: logic))
        PreferencesDialog.remoteAccessPage = { [weak logic] runCommand in
            guard let logic else { return nil }
            return RemoteAccessPreferencesPage.make(logic: logic, runCommand: runCommand)
        }
        installRemoteAccessAutomation(logic: logic)
    }

    /// Script commands for scripted runs (with TOASTTY_LINUX_FAKE_TAILNET_ORIGIN):
    ///
    ///     remote-access enable    # turn the gateway on, wait until it can pair
    ///     remote-access pair      # issue a pairing offer (QR + fallback code)
    ///     expect remoteAccess=ready remotePairing=true
    private func installRemoteAccessAutomation(logic: LinuxAppLogic) {
        AutomationScript.extensionCommands["remote-access"] = { [weak logic] _, argument, script in
            guard let logic, logic.isRemoteAccessAvailable else { script.reportFailure("remote-access: unavailable"); return }
            switch argument {
            case "enable":
                if let origin = ProcessInfo.processInfo.environment["TOASTTY_LINUX_FAKE_TAILNET_ORIGIN"] {
                    logic.setRemoteAccessTailnetOrigin(origin)
                }
                logic.setRemoteAccessEnabled(true)
                guard MainLoop.spin(untilMilliseconds: 10_000, { logic.remoteAccessStatus?.canIssuePairingOffer == true }) else {
                    script.reportFailure("remote-access enable: not ready (\(logic.remoteAccessStatus?.detail ?? "no status"))")
                    return
                }
            case "pair":
                logic.issueRemoteAccessPairingOffer()
                if MainLoop.spin(untilMilliseconds: 5_000, { logic.remoteAccessStatus?.pairingFallbackCode != nil }) == false {
                    script.reportFailure("remote-access pair: no pairing offer")
                }
            default:
                script.reportFailure("remote-access: unknown argument \(argument)")
            }
        }
        AutomationScript.summaryContributors.append { [weak logic] _ in
            guard let status = logic?.remoteAccessStatus else { return ["remoteAccess": "unavailable"] }
            let state = switch status.indicator {
            case .off: "off"
            case .progress: "progress"
            case .ready: "ready"
            case .failure: "failure"
            }
            return [
                "remoteAccess": state,
                "remotePairing": String(status.pairingFallbackCode != nil),
                "remoteQRCode": String(logic?.remoteAccessPairingQRCodePNG != nil),
            ]
        }
    }
}

/// The Preferences "Remote Access" page: the enable switch and status, with
/// pairing and devices in the Remote Access window.
@MainActor
enum RemoteAccessPreferencesPage {
    static func make(logic: LinuxAppLogic, runCommand: @escaping (String) -> Void) -> WidgetPtr {
        let page = adw_preferences_page_new()!
        adw_preferences_page_set_title(cast(page), "Remote Access")
        adw_preferences_page_set_icon_name(cast(page), "network-wireless-symbolic")
        let group = RemoteAccessDialog.group("Remote Access", "Follow and answer agent sessions from the Toastty iOS app over Tailscale.")
        let status = logic.remoteAccessStatus
        let enable = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(enable), "Enable Remote Access")
        adw_action_row_set_subtitle(cast(enable), status.map { "\($0.title) · \($0.detail)" } ?? "Unavailable in this instance")
        adw_switch_row_set_active(cast(enable), (status?.isEnabled ?? false).gboolean)
        gtk_widget_set_sensitive(enable, (status != nil).gboolean)
        Signal.notify(enable, "active") { logic.setRemoteAccessEnabled(adw_switch_row_get_active(cast(enable)).bool) }
        adw_preferences_group_add(cast(group), enable)
        let open = adw_action_row_new()!
        adw_preferences_row_set_title(cast(open), "Pairing and Devices")
        adw_action_row_set_subtitle(cast(open), "\(status?.devices.filter { $0.isRevoked == false }.count ?? 0) paired · show the pairing code")
        adw_action_row_add_suffix(cast(open), Gtk.image("go-next-symbolic"))
        gtk_list_box_row_set_activatable(cast(open), 1)
        Signal.connect(open, "activated") { runCommand("app.remote-access.open") }
        adw_preferences_group_add(cast(group), open)
        adw_preferences_page_add(cast(page), cast(group))
        return widget(page)
    }
}
#endif
