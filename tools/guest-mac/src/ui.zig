//! The windowed guest-mac host: Native SDK chrome around the live guest
//! display. The display area is a plain `stack` container filling the
//! declared shell scene; once the engine configures the VM, its
//! VZVirtualMachineView is adopted into that container through the
//! native-surface channel (`Runtime.adoptViewSurface`) — pointer/keyboard
//! capture inside the guest is the view's own behavior from there.
//!
//! The app self-drives the honest happy path on a poll timer: fetch the
//! restore image if it is not cached, install if the bundle is missing
//! (progress in the statusbar), configure, and wait for Start. Setup
//! Assistant click-through happens right here in the display area — the
//! one manual step.
//!
//! Provisioning guidance lives in a HELP WINDOW, model-declared through
//! the framework's secondary-window channel: `help_open` is the
//! visibility (presence IS visibility — the reconcile creates the window
//! while the flag is set and closes it when cleared), and a user close
//! arrives as `.window_closed` so the model owns the flag either way.
//! This app is scene-based (its content is an adopted native view, not a
//! canvas), so it drives the same runtime channel `UiApp.Options.
//! windows_fn` wraps — `createSourcelessShellWindow` + `.window_closed`
//! — directly.
//!
//! The window drives ONE named VM, chosen by the `--name` launch flag;
//! an in-app VM switcher is deferred.

const std = @import("std");
const native_sdk = @import("native_sdk");
const vm = @import("vm.zig");
const cli = @import("cli.zig");

const tick_timer_id: u64 = 1;
const tick_interval_ns: u64 = 500 * std.time.ns_per_ms;

// The provisioning-checklist sidebar is gone (its content moved to the
// help window), so the window is chrome + the guest display and the
// default size shrinks by the old sidebar's width.
pub const window_width: f32 = 1040;
pub const window_height: f32 = 900;
const toolbar_height: f32 = 52;
const statusbar_height: f32 = 34;

const start_command = "vm.start";
const stop_command = "vm.stop";
const force_stop_command = "vm.force-stop";
pub const help_command = "vm.help";

pub const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };

pub const shell_views = [_]native_sdk.ShellView{
    .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = toolbar_height, .layer = 20, .role = "Toolbar" },
    .{ .label = "toolbar-title", .kind = .label, .parent = "toolbar", .x = 18, .y = 16, .width = 180, .height = 20, .layer = 21, .text = "Guest macOS" },
    .{ .label = "start", .kind = .button, .parent = "toolbar", .x = 210, .y = 11, .width = 88, .height = 30, .layer = 21, .text = "Start", .command = start_command, .accessibility_label = "Start the guest VM" },
    .{ .label = "stop", .kind = .button, .parent = "toolbar", .x = 306, .y = 11, .width = 88, .height = 30, .layer = 21, .text = "Stop", .command = stop_command, .accessibility_label = "Gracefully stop the guest VM" },
    .{ .label = "force-stop", .kind = .button, .parent = "toolbar", .x = 402, .y = 11, .width = 110, .height = 30, .layer = 21, .text = "Force Stop", .command = force_stop_command, .accessibility_label = "Force stop the guest VM" },
    .{ .label = "help", .kind = .button, .parent = "toolbar", .x = 520, .y = 11, .width = 72, .height = 30, .layer = 21, .text = "Help", .command = help_command, .accessibility_label = "Open the provisioning help window" },
    .{ .label = "guest-display", .kind = .stack, .fill = true, .layer = 10, .role = "Guest display", .accessibility_label = "Live guest macOS display" },
    .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = statusbar_height, .layer = 20, .role = "Status" },
    .{ .label = "status-label", .kind = .label, .parent = "statusbar", .x = 14, .y = 8, .width = 760, .height = 18, .layer = 21, .text = "Starting engine..." },
    .{ .label = "busy", .kind = .progress_indicator, .parent = "statusbar", .x = 784, .y = 7, .width = 20, .height = 20, .layer = 21, .visible = false, .accessibility_label = "Working" },
};

pub const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Guest macOS",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ---- help window --------------------------------------------------------------

pub const help_window_label = "help";

const HelpSection = struct {
    title: []const u8,
    lines: []const []const u8,
};

/// The provisioning story, grouped by phase — the multi-VM world:
/// named guests, clone, the one manual mount, the access grants, and
/// the etiquette for sharing a guest between agents.
const help_sections = [_]HelpSection{
    .{ .title = "First boot", .lines = &.{
        "Fetch and install run here automatically.",
        "Press Start, then click through Setup Assistant",
        "in the display area (the one manual step).",
        "Create the account agents will SSH in as.",
    } },
    .{ .title = "Enable access (in the guest)", .lines = &.{
        "System Settings > General > Sharing:",
        "turn Remote Login ON.",
        "Privacy & Security > Screen Recording:",
        "allow the SSH session's runner (sshd-child) so",
        "screen captures work over SSH.",
    } },
    .{ .title = "Mount the repo share (once)", .lines = &.{
        "In the guest Terminal:",
        "mkdir -p /Volumes/repo",
        "sudo mount_virtiofs repo /Volumes/repo",
        "/Volumes/repo/tools/guest-mac/provision.sh",
        "installs the pinned Zig and a boot-time remount.",
        "The share is read-only: build with a guest-local",
        "ZIG_LOCAL_CACHE_DIR, never into the mount.",
    } },
    .{ .title = "Named guests and clones", .lines = &.{
        "Bundles live at ~/.native/guest-mac/vms/<name>.",
        "Every verb takes --name VM (default \"default\").",
        "guest-mac clone <src> <dst> copies a stopped,",
        "provisioned guest copy-on-write with a fresh",
        "machine identity and MAC — the clone keeps the",
        "user, keys, and tools, and gets its own IP.",
        "This window drives one VM: launch with --name.",
    } },
    .{ .title = "Two guests at most", .lines = &.{
        "Apple's macOS license permits two macOS guests",
        "running concurrently per host; start refuses a",
        "third and names the running VMs.",
    } },
    .{ .title = "Sharing one guest between agents", .lines = &.{
        "App-scoped automation (widget verbs, engine",
        "screenshots, builds) may run concurrently.",
        "Real input (CGEvent gestures, full-desktop",
        "captures) is exclusive: take the input lock",
        "described in agents.md before driving it.",
    } },
    .{ .title = "Connect", .lines = &.{
        "guest-mac ip --name <vm> --wait 120",
        "ssh <user>@<ip>",
    } },
};

const help_margin: f32 = 20;
const help_title_height: f32 = 22;
const help_line_height: f32 = 20;
const help_section_gap: f32 = 18;
const help_text_width: f32 = 380;
const help_body_indent: f32 = 12;
const help_column_width: f32 = help_text_width + help_body_indent;

fn helpViewCount() usize {
    return 1 + help_sections.len * 2; // the body stack + heading/body per section
}

fn helpSectionHeight(section: HelpSection) f32 {
    return help_title_height + @as(f32, @floatFromInt(section.lines.len)) * help_line_height + help_section_gap;
}

/// Sections flow into the left column until half the total content
/// height is placed, then the right column — two balanced columns keep
/// every section visible on a laptop screen (the shell-view channel has
/// no scroll container).
fn helpColumnHeight() f32 {
    var total: f32 = 0;
    for (help_sections) |section| total += helpSectionHeight(section);
    var left: f32 = 0;
    var right: f32 = 0;
    for (help_sections) |section| {
        if (left < total / 2) left += helpSectionHeight(section) else right += helpSectionHeight(section);
    }
    return @max(left, right);
}

fn joinLines(comptime lines: []const []const u8) []const u8 {
    comptime var joined: []const u8 = "";
    inline for (lines, 0..) |line, index| {
        joined = joined ++ (if (index == 0) "" else "\n") ++ line;
    }
    return joined;
}

/// The help window's views, generated from `help_sections` at comptime:
/// a heading label plus ONE multiline body label per section (the
/// app-wide native-view budget is small, so sections do not spend a
/// view per line), flowed into two columns inside a filling stack.
/// Native labels, no webview.
fn helpViews() [helpViewCount()]native_sdk.ShellView {
    var total: f32 = 0;
    for (help_sections) |section| total += helpSectionHeight(section);

    var views: [helpViewCount()]native_sdk.ShellView = undefined;
    views[0] = .{ .label = "help-body", .kind = .stack, .fill = true, .layer = 10, .role = "Provisioning help" };
    var index: usize = 1;
    var placed: f32 = 0;
    var column_y = [2]f32{ help_margin, help_margin };
    for (help_sections, 0..) |section, section_index| {
        const column: usize = if (placed < total / 2) 0 else 1;
        placed += helpSectionHeight(section);
        const x = help_margin + @as(f32, @floatFromInt(column)) * (help_column_width + help_margin);
        views[index] = .{
            .label = std.fmt.comptimePrint("help-s{d}-title", .{section_index}),
            .kind = .label,
            .parent = "help-body",
            .x = x,
            .y = column_y[column],
            .width = help_text_width,
            .height = help_title_height,
            .layer = 11,
            .text = section.title,
            .role = "Section heading",
        };
        index += 1;
        column_y[column] += help_title_height;
        const body_height = @as(f32, @floatFromInt(section.lines.len)) * help_line_height;
        views[index] = .{
            .label = std.fmt.comptimePrint("help-s{d}-body", .{section_index}),
            .kind = .label,
            .parent = "help-body",
            .x = x + help_body_indent,
            .y = column_y[column],
            .width = help_text_width,
            .height = body_height,
            .layer = 11,
            .text = joinLines(section.lines),
        };
        index += 1;
        column_y[column] += body_height + help_section_gap;
    }
    return views;
}

pub const help_views = helpViews();
pub const help_window = native_sdk.ShellWindow{
    .label = help_window_label,
    .title = "Guest Provisioning Help",
    .width = 2 * help_column_width + 3 * help_margin,
    // Sized to the content and resizable — every section is visible
    // without a scroll container.
    .height = helpColumnHeight() + 2 * help_margin,
    .resizable = true,
    .restore_state = false,
    .views = &help_views,
};

const Phase = enum {
    boot,
    fetching,
    installing,
    configuring,
    ready,
    blocked,
};

pub const GuestMacApp = struct {
    events: vm.Events = .{},
    engine: ?vm.Engine = null,
    paths: vm.Paths = .{},
    /// The named VM this window drives (`--name` launch flag).
    vm_name: []const u8 = cli.default_vm_name,
    phase: Phase = .boot,
    display_adopted: bool = false,
    install_kicked: bool = false,
    /// Help window visibility: the model bool IS the channel
    /// (presence-is-visibility, reconciled after every event that
    /// changes it; a user close clears it via `.window_closed`).
    help_open: bool = false,
    /// Live help window id, 0 while closed.
    help_window_id: u64 = 0,
    ip_buffer: [64]u8 = @splat(0),
    ip_len: usize = 0,
    ip_poll_countdown: u32 = 0,
    last_status: [256]u8 = @splat(0),
    last_status_len: usize = 0,
    busy_visible: bool = false,

    pub fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "guest-mac",
            .scene_fn = scene,
            .start_fn = start,
            .event_fn = event,
        };
    }

    fn scene(context: *anyopaque) anyerror!native_sdk.ShellConfig {
        _ = context;
        return shell_scene;
    }

    fn start(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        _ = context;
        try runtime.startTimer(tick_timer_id, tick_interval_ns, true);
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .command => |command| {
                if (std.mem.eql(u8, command.name, start_command)) {
                    self.startGuest(runtime);
                } else if (std.mem.eql(u8, command.name, stop_command)) {
                    if (self.engine) |engine| engine.requestStop() catch self.note(runtime, "stop request failed (guest not running?)");
                } else if (std.mem.eql(u8, command.name, force_stop_command)) {
                    if (self.engine) |engine| engine.forceStop() catch self.note(runtime, "force stop failed (guest not running?)");
                } else if (std.mem.eql(u8, command.name, help_command)) {
                    self.help_open = !self.help_open;
                    self.reconcileHelpWindow(runtime);
                }
            },
            .timer => |timer| {
                if (timer.id == tick_timer_id) self.tick(runtime);
            },
            .window_closed => |closed| {
                // The user closed the help window: it is already gone
                // (the optimistic echo) — the model owns the flag.
                if (closed.window_id == self.help_window_id) {
                    self.help_window_id = 0;
                    self.help_open = false;
                }
            },
            else => {},
        }
    }

    /// Reconcile the declared help window against the live one —
    /// presence-is-visibility, the b9d7dc0 window channel driven from
    /// this scene-based app's own model flag.
    fn reconcileHelpWindow(self: *@This(), runtime: *native_sdk.Runtime) void {
        if (self.help_open and self.help_window_id == 0) {
            const info = runtime.createSourcelessShellWindow(help_window) catch {
                self.help_open = false;
                self.note(runtime, "help window failed to open");
                return;
            };
            self.help_window_id = info.id;
        } else if (!self.help_open and self.help_window_id != 0) {
            const window_id = self.help_window_id;
            self.help_window_id = 0;
            runtime.closeWindow(window_id) catch {};
        }
    }

    fn tick(self: *@This(), runtime: *native_sdk.Runtime) void {
        if (self.phase == .blocked) return;
        if (self.engine == null) self.bootstrap(runtime);
        const engine = self.engine orelse return;
        self.advance(runtime, engine);
        self.adoptDisplayIfReady(runtime, engine);
        self.pollGuestIp(engine);
        self.refreshStatus(runtime);
    }

    fn bootstrap(self: *@This(), runtime: *native_sdk.Runtime) void {
        const home = vm.homeDir() orelse {
            self.block(runtime, "HOME is not set — cannot locate the VM bundle");
            return;
        };
        self.paths = vm.resolvePaths(home, self.vm_name) catch {
            self.block(runtime, "home path too long for the VM bundle location");
            return;
        };
        if (self.otherInstancePid()) |pid| {
            var buffer: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "guest already running headless (pid {d}) — `guest-mac stop` first", .{pid}) catch "guest already running headless";
            self.block(runtime, text);
            return;
        }
        self.engine = vm.Engine.create(self.paths.bundleDir(), self.paths.cacheDir(), &self.events) catch {
            self.block(runtime, "Virtualization engine unavailable (Apple silicon macOS 13+ required)");
            return;
        };
    }

    /// The self-driving happy path: no bundle -> fetch -> install ->
    /// configure -> ready(stopped). Every step is engine-async; this just
    /// notices completion on the poll tick and kicks the next step.
    fn advance(self: *@This(), runtime: *native_sdk.Runtime, engine: vm.Engine) void {
        _ = runtime;
        if (self.events.failed) return;
        switch (self.phase) {
            .boot => {
                if (self.events.state == .no_bundle) {
                    engine.fetchRestoreImage() catch return;
                    self.phase = .fetching;
                } else {
                    // Bundle already installed: configure straight away.
                    self.phase = .configuring;
                }
            },
            .fetching => {
                if (self.events.ipswPath()) |path| {
                    if (self.events.state == .no_bundle and !self.install_kicked) {
                        self.install_kicked = true;
                        engine.install(path, cli.default_cpus, cli.default_memory_gb << 30, cli.default_disk_gb << 30) catch return;
                        self.phase = .installing;
                    } else if (self.events.state == .stopped) {
                        self.phase = .configuring;
                    }
                }
            },
            .installing => {
                if (self.events.state == .stopped) self.phase = .configuring;
            },
            .configuring => {
                var cwd_buffer: [512]u8 = undefined;
                // Share the repo root, not the launch cwd (the windowed app is
                // usually launched from the tool directory).
                const share_dir = vm.repoRootOrCwd(&cwd_buffer);
                engine.configure(share_dir, cli.default_share_tag, cli.default_cpus, cli.default_memory_gb << 30) catch return;
                self.phase = .ready;
            },
            .ready, .blocked => {},
        }
    }

    fn adoptDisplayIfReady(self: *@This(), runtime: *native_sdk.Runtime, engine: vm.Engine) void {
        if (self.display_adopted) return;
        const view = engine.displayView() orelse return;
        runtime.adoptViewSurface(1, "guest-display", view) catch return;
        self.display_adopted = true;
    }

    fn startGuest(self: *@This(), runtime: *native_sdk.Runtime) void {
        const engine = self.engine orelse return;
        if (self.phase != .ready or (self.events.state != .stopped and self.events.state != .no_bundle)) {
            self.note(runtime, "guest is not ready to start yet");
            return;
        }
        engine.start() catch self.note(runtime, "start failed — see state");
    }

    fn pollGuestIp(self: *@This(), engine: vm.Engine) void {
        if (self.events.state != .running) {
            self.ip_len = 0;
            return;
        }
        if (self.ip_len > 0) return;
        if (self.ip_poll_countdown > 0) {
            self.ip_poll_countdown -= 1;
            return;
        }
        self.ip_poll_countdown = 4; // every ~2s on the 500ms tick
        var mac_buffer: [32]u8 = undefined;
        const mac = engine.macAddress(&mac_buffer) orelse return;
        var leases_buffer: [64 * 1024]u8 = undefined;
        const leases = vm.readFileInto(vm.dhcpd_leases_path, &leases_buffer) orelse return;
        const ip = cli.leaseIpForMac(leases, mac) orelse return;
        self.ip_len = @min(ip.len, self.ip_buffer.len);
        @memcpy(self.ip_buffer[0..self.ip_len], ip[0..self.ip_len]);
    }

    fn refreshStatus(self: *@This(), runtime: *native_sdk.Runtime) void {
        var buffer: [256]u8 = undefined;
        const status = self.statusText(&buffer);
        if (!std.mem.eql(u8, status, self.last_status[0..self.last_status_len])) {
            self.last_status_len = @min(status.len, self.last_status.len);
            @memcpy(self.last_status[0..self.last_status_len], status[0..self.last_status_len]);
            _ = runtime.updateView(1, "status-label", .{ .text = status }) catch {};
        }
        const busy = self.events.state == .fetching or self.events.state == .installing or self.events.state == .starting or self.events.state == .stopping;
        if (busy != self.busy_visible) {
            self.busy_visible = busy;
            _ = runtime.updateView(1, "busy", .{ .visible = busy }) catch {};
        }
    }

    fn statusText(self: *@This(), buffer: []u8) []const u8 {
        if (self.events.failed) {
            return std.fmt.bufPrint(buffer, "error: {s}", .{self.events.lastMessage()}) catch "error";
        }
        return switch (self.events.state) {
            .no_bundle => "no VM bundle yet",
            .fetching => if (self.events.download_progress > 0)
                std.fmt.bufPrint(buffer, "fetching restore image... {d}%", .{@as(u32, @intFromFloat(self.events.download_progress * 100))}) catch "fetching restore image..."
            else
                "fetching restore image...",
            .installing => std.fmt.bufPrint(buffer, "installing macOS... {d}%", .{@as(u32, @intFromFloat(self.events.install_progress * 100))}) catch "installing macOS...",
            .stopped => if (self.phase == .ready) "stopped — press Start (first boot: click through Setup Assistant here)" else "stopped",
            .starting => "booting...",
            .running => if (self.ip_len > 0)
                std.fmt.bufPrint(buffer, "running — ip {s} (ssh in, or use the display)", .{self.ip_buffer[0..self.ip_len]}) catch "running"
            else
                "running — waiting for DHCP lease...",
            .stopping => "stopping...",
            .err => "error",
        };
    }

    fn note(self: *@This(), runtime: *native_sdk.Runtime, text: []const u8) void {
        _ = self;
        _ = runtime.updateView(1, "status-label", .{ .text = text }) catch {};
    }

    fn block(self: *@This(), runtime: *native_sdk.Runtime, text: []const u8) void {
        self.phase = .blocked;
        self.note(runtime, text);
    }

    fn otherInstancePid(self: *@This()) ?i32 {
        const pid = vm.livePidForBundle(self.paths.bundleDir()) orelse return null;
        if (pid == @as(i32, @intCast(std.c.getpid()))) return null;
        return pid;
    }
};

// ---- tests ----------------------------------------------------------------------

test "guest-mac scene is chrome plus the guest display — no sidebar, no webview" {
    var display: ?native_sdk.ShellView = null;
    var status: ?native_sdk.ShellView = null;
    var help_button: ?native_sdk.ShellView = null;
    var buttons: usize = 0;
    for (shell_views) |view| {
        if (std.mem.eql(u8, view.label, "guest-display")) display = view;
        if (std.mem.eql(u8, view.label, "status-label")) status = view;
        if (std.mem.eql(u8, view.label, "help")) help_button = view;
        if (view.kind == .button) buttons += 1;
        // The provisioning checklist moved to the help window: the main
        // scene declares no sidebar (the window shrank accordingly).
        try std.testing.expect(view.kind != .sidebar);
        // Fully native: no webview anywhere, so no implicit main webview.
        try std.testing.expect(view.kind != .webview);
    }
    try std.testing.expect(display.?.kind == .stack);
    try std.testing.expect(display.?.fill);
    try std.testing.expect(status.?.kind == .label);
    try std.testing.expectEqual(@as(usize, 4), buttons);
    try std.testing.expectEqualStrings(help_command, help_button.?.command.?);
    try std.testing.expectEqual(@as(f32, 1040), shell_windows[0].width);
}

test "the help window carries every provisioning section as native labels" {
    try std.testing.expectEqualStrings(help_window_label, help_window.label);
    try std.testing.expect(help_window.views.len == helpViewCount());
    // Every section heading is present, in order, and every view is a
    // label inside the body stack (no webview, no monospace blob).
    var heading_count: usize = 0;
    for (help_window.views) |view| {
        if (view.kind == .stack) continue;
        try std.testing.expect(view.kind == .label);
        try std.testing.expectEqualStrings("help-body", view.parent.?);
        for (help_sections) |section| {
            if (std.mem.eql(u8, view.text.?, section.title)) heading_count += 1;
        }
    }
    try std.testing.expectEqual(help_sections.len, heading_count);
    // Content-sized: tall enough for the taller column, and short
    // enough for a laptop screen (no scroll channel exists to hide
    // overflow behind).
    try std.testing.expect(help_window.height >= helpColumnHeight());
    try std.testing.expect(help_window.height <= 700);
    // Every view sits inside the window's declared bounds.
    for (help_window.views) |view| {
        if (view.kind == .stack) continue;
        try std.testing.expect(view.x.? + view.width.? <= help_window.width);
        try std.testing.expect(view.y.? + view.height.? <= help_window.height);
    }
}

test "the help window opens by command and round-trips both close paths through real dispatch" {
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{ .size = native_sdk.geometry.SizeF.init(window_width, window_height) });
    defer harness.destroy(std.testing.allocator);
    var app_state = GuestMacApp{};
    const app = app_state.app();
    try harness.start(app);

    // Closed at launch.
    try std.testing.expect(helpWindowInfo(harness) == null);
    try std.testing.expect(!app_state.help_open);

    // The toolbar command opens it: flag set, live platform window.
    try dispatchHelpCommand(harness, app);
    try std.testing.expect(app_state.help_open);
    const info = helpWindowInfo(harness) orelse return error.TestUnexpectedResult;
    try std.testing.expect(info.open);
    try std.testing.expectEqualStrings("Guest Provisioning Help", info.title);
    try std.testing.expectEqual(app_state.help_window_id, info.id);

    // Toggling again closes it (the reconcile close — the model stopped
    // declaring it).
    try dispatchHelpCommand(harness, app);
    try std.testing.expect(!app_state.help_open);
    try std.testing.expectEqual(@as(u64, 0), app_state.help_window_id);
    const closed = helpWindowInfo(harness);
    try std.testing.expect(closed == null or !closed.?.open);

    // Reopen under the same label, then the USER closes it: the window
    // is already gone and `.window_closed` clears the model flag.
    try dispatchHelpCommand(harness, app);
    const reopened = helpWindowInfo(harness) orelse return error.TestUnexpectedResult;
    const close_event = harness.null_platform.userCloseWindow(reopened.id) orelse return error.TestUnexpectedResult;
    try harness.runtime.dispatchPlatformEvent(app, close_event);
    try std.testing.expect(!app_state.help_open);
    try std.testing.expectEqual(@as(u64, 0), app_state.help_window_id);

    // And the label is free again: a fresh open works after a user close.
    try dispatchHelpCommand(harness, app);
    try std.testing.expect(app_state.help_open);
    try std.testing.expect(helpWindowInfo(harness) != null);
}

fn dispatchHelpCommand(harness: *native_sdk.TestHarness(), app: native_sdk.App) !void {
    // The native-view command path — what the real toolbar button emits.
    try harness.runtime.dispatchPlatformEvent(app, .{ .native_command = .{ .name = help_command, .window_id = 1, .view_label = "help" } });
}

fn helpWindowInfo(harness: *native_sdk.TestHarness()) ?native_sdk.platform.WindowInfo {
    var buffer: [native_sdk.platform.max_windows]native_sdk.platform.WindowInfo = undefined;
    for (harness.runtime.listWindows(&buffer)) |info| {
        if (std.mem.eql(u8, info.label, help_window_label)) return info;
    }
    return null;
}

test "status text tracks engine state" {
    var app_state: GuestMacApp = .{};
    var buffer: [256]u8 = undefined;
    app_state.events.state = .installing;
    app_state.events.install_progress = 0.42;
    try std.testing.expectEqualStrings("installing macOS... 42%", app_state.statusText(&buffer));
    app_state.events.state = .running;
    const ip = "192.168.64.9";
    @memcpy(app_state.ip_buffer[0..ip.len], ip);
    app_state.ip_len = ip.len;
    try std.testing.expectEqualStrings("running — ip 192.168.64.9 (ssh in, or use the display)", app_state.statusText(&buffer));
    app_state.events.failed = true;
    app_state.events.record(.err, .err, 0, "boom");
    try std.testing.expectEqualStrings("error: boom", app_state.statusText(&buffer));
}
