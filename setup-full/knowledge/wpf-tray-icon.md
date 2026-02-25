# WPF System Tray Icon — Knowledge Base

> **Context-free reference for implementing system tray icons in WPF/.NET applications**
> Distilled from hard-won lessons implementing tray icons in a .NET 8 WPF application.

---

## Problem Statement

**WPF has no built-in system tray icon (NotifyIcon) component.**

Unlike Windows Forms (which has `System.Windows.Forms.NotifyIcon` wrapping Win32's `Shell_NotifyIcon`), WPF never shipped a NotifyIcon control. This forces developers to choose between:

1. Third-party NuGet packages (spoiler: they're all broken)
2. WinForms interop (the only working solution)

---

## The Solution: WinForms NotifyIcon

**TL;DR: Use `System.Windows.Forms.NotifyIcon` with `<UseWindowsForms>true</UseWindowsForms>` in your WPF project.**

### Why WinForms?

- `System.Windows.Forms.NotifyIcon` is a thin, battle-tested wrapper around Win32's `Shell_NotifyIcon`
- Built into .NET runtime — no third-party dependencies
- Rock solid since Windows XP, works perfectly in .NET 8+
- Zero issues when used in WPF apps with proper configuration

### Implementation Pattern

**Step 1: Enable WinForms in your WPF project**

```xml
<PropertyGroup>
  <UseWPF>true</UseWPF>
  <UseWindowsForms>true</UseWindowsForms>
</PropertyGroup>
```

**Step 2: Create the NotifyIcon**

```csharp
using WinForms = System.Windows.Forms;

public class TrayIconManager : IDisposable
{
    private WinForms.NotifyIcon _notifyIcon;

    public void Initialize()
    {
        _notifyIcon = new WinForms.NotifyIcon
        {
            Text = "My App - Idle",                         // Tooltip text
            Icon = System.Drawing.SystemIcons.Application,  // Fallback icon
            ContextMenuStrip = BuildContextMenu(),          // Right-click menu
            Visible = true                                  // Must be explicitly set
        };
    }

    private WinForms.ContextMenuStrip BuildContextMenu()
    {
        var menu = new WinForms.ContextMenuStrip();

        var actionItem = new WinForms.ToolStripMenuItem("Do Something");
        actionItem.Click += (s, e) => { /* handler */ };
        menu.Items.Add(actionItem);

        menu.Items.Add(new WinForms.ToolStripSeparator());

        var exitItem = new WinForms.ToolStripMenuItem("Exit");
        exitItem.Click += (s, e) =>
        {
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            System.Windows.Application.Current.Shutdown();
        };
        menu.Items.Add(exitItem);

        return menu;
    }

    public void ShowNotification(string title, string text)
    {
        _notifyIcon.ShowBalloonTip(
            timeout: 3000,
            tipTitle: title,
            tipText: text,
            tipIcon: WinForms.ToolTipIcon.Info  // Info, Warning, Error, None
        );
    }

    public void Dispose()
    {
        if (_notifyIcon != null)
        {
            _notifyIcon.Visible = false;  // Remove from tray BEFORE disposing
            _notifyIcon.Dispose();
        }
    }
}
```

---

## What Doesn't Work: Third-Party Packages

All third-party tray icon packages are either abandoned, broken on modern .NET, or incompatible with common architectures.

### `Hardcodet.NotifyIcon.Wpf` 1.1.0
- **Problem**: Targets .NET Framework, not .NET Core/.NET 8
- **Symptoms**: Compiles, but icon is invisible (missing interop for modern DPI handling)
- **Status**: Abandoned (last update 2018)

### `Hardcodet.NotifyIcon.Wpf.NetCore` 1.1.5
- **Problem**: Runtime crash on .NET 8
- **Error**: `MissingMethodException: Method not found: 'Void Hardcodet.Wpf.TaskbarNotification.Interop.WindowMessageSink.add_DpiChanged(System.Action)'`
- **Status**: Dead project, no maintainer

### `H.NotifyIcon.Wpf` 2.2.0
- **Problem**: Causes `Host.CreateDefaultBuilder().Build()` to deadlock (see below)
- **Details**: Assembly-level initialization appears to interfere with WPF's dispatcher during Generic Host construction
- **Bonus problem**: Requires `System.Drawing.Common >= 9.0.0` (NU1605 version conflict with .NET 8 apps)
- **Status**: Actively maintained but incompatible with Generic Host architecture

**Bottom line**: Don't waste time on packages. WinForms NotifyIcon works flawlessly.

---

## Critical Issue: Host.Build() Deadlocks on WPF Dispatcher

### The Bug

**`Host.CreateDefaultBuilder().Build()` deadlocks when called from WPF's `OnStartup` method** (which runs on the dispatcher thread). The call never returns. This happens **even without any third-party packages** — it's a fundamental interaction between Generic Host and WPF's threading model.

### Symptoms

- App launches, process is alive (typically 40-60MB), but nothing happens
- Diagnostic file writes stop at the `.Build()` call
- Even `await Task.Run(() => builder.Build())` doesn't fix it (the `await` continuation needs the dispatcher, which was blocked by the synchronous part of `OnStartup`)

### Root Cause (Suspected)

`Host.CreateDefaultBuilder()` registers `FileConfigurationProvider` (for `appsettings.json` file watching) which creates a `FileSystemWatcher`. The watcher's initialization appears to post work to the `SynchronizationContext` (WPF's `DispatcherSynchronizationContext`), causing a deadlock when the dispatcher thread is blocked waiting for Build() to complete.

### The Fix: Synchronous UI First, Fire-and-Forget Host

```csharp
public partial class App : Application
{
    private TrayIconManager _trayManager;
    private IHost _host;

    protected override void OnStartup(StartupEventArgs e)  // NOT async void
    {
        base.OnStartup(e);

        // 1. Create tray icon synchronously — this works immediately
        _trayManager = new TrayIconManager();
        _trayManager.Initialize();

        // 2. Build host entirely off the UI thread (fire-and-forget)
        Task.Run(async () =>
        {
            var host = Host.CreateDefaultBuilder()
                .ConfigureLogging(logging =>
                {
                    logging.ClearProviders();
                    logging.AddConsole();
                })
                .ConfigureServices((context, services) =>
                {
                    // Register your services
                    services.AddSingleton<IMyService, MyService>();
                })
                .Build();

            _host = host;
            await host.StartAsync();

            // 3. Wire DI services back to UI on the dispatcher thread
            Dispatcher.Invoke(() =>
            {
                _trayManager.SetServices(host.Services);
            });
        });
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayManager?.Dispose();
        _host?.StopAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
        _host?.Dispose();
        base.OnExit(e);
    }
}
```

**Key principles:**

1. **`OnStartup` must NOT be `async`** — no `await` means the dispatcher is immediately free to pump messages
2. **The entire host lifecycle (Build + StartAsync) runs on a threadpool thread** via `Task.Run`
3. **`Dispatcher.Invoke` safely marshals back to the UI thread** after the host is ready
4. **The TrayIconManager must gracefully handle null services** during the brief startup window (menu items won't work until `SetServices` is called)

---

## Critical Gotcha: Namespace Collisions

Adding `<UseWindowsForms>true</UseWindowsForms>` imports WinForms types that **collide with WPF types**. You must add type aliases in every affected file:

```csharp
// At the top of each WPF file that uses Application, MessageBox, etc.
using Application = System.Windows.Application;
using StartupEventArgs = System.Windows.StartupEventArgs;
using ExitEventArgs = System.Windows.ExitEventArgs;
using MessageBox = System.Windows.MessageBox;
using Clipboard = System.Windows.Clipboard;

// Use WinForms namespace for NotifyIcon types
using WinForms = System.Windows.Forms;
```

If you forget these, you'll get `CS0104: 'X' is an ambiguous reference between 'System.Windows.X' and 'System.Windows.Forms.X'` errors.

---

## Windows Notification Area Behavior

### New Apps Default to Hidden

**Windows hides tray icons from new/unknown apps by default.** The user must manually enable it:

**Settings → Personalization → Taskbar → Other system tray icons → [Your App] → On**

This is a one-time action per app, but:

- Each unique exe path creates a **separate entry** in the list
- Rebuilding to a different output path = new entry (old one stays as stale ghost)
- If "Hidden icons menu" is disabled in taskbar settings, there is **no overflow chevron (^)** — disabled icons are simply invisible

### Installer Can Auto-Enable (Advanced)

An installer can write registry values to auto-show the icon, but for dev/testing it's always manual. The registry path is:

```
HKEY_CURRENT_USER\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\TrayNotify
```

This is complex and typically not worth the effort for most applications.

---

## Key Gotchas and Tips

### 1. Icon Disposal Order Matters

```csharp
public void Dispose()
{
    _notifyIcon.Visible = false;  // Remove from tray FIRST
    _notifyIcon.Dispose();        // Then dispose
}
```

Disposing before setting `Visible = false` can leave ghost icons in the tray.

### 2. Icon Format Requirements

- `System.Drawing.Icon` accepts `.ico` files (multi-resolution preferred)
- `System.Drawing.SystemIcons` provides fallback icons (Application, Information, Warning, Error)
- For custom icons, embed as `Resource` in your project

### 3. Context Menu Disposal

If you rebuild the context menu dynamically (e.g., based on app state), remember to dispose the old one:

```csharp
public void UpdateMenu()
{
    var oldMenu = _notifyIcon.ContextMenuStrip;
    _notifyIcon.ContextMenuStrip = BuildContextMenu();
    oldMenu?.Dispose();
}
```

### 4. Balloon Tips Are Not Guaranteed

Windows may suppress balloon tips if:
- The user has disabled notifications for your app
- Focus Assist is enabled
- Too many notifications have been shown recently

Always have a fallback UI pattern (e.g., status in the context menu).

### 5. Debugging Tips

- **Use file-based diagnostics**: `System.IO.File.AppendAllText(Path.GetTempPath() + "diag.txt", msg)` — this works regardless of output type or console state
- **Console.WriteLine in WPF**: Only works with `<OutputType>Exe</OutputType>` (shows a console window), but cannot be captured via PowerShell's `Start-Process -RedirectStandardOutput`
- **WPF's async void swallows exceptions**: If `OnStartup` is `async void`, unhandled exceptions are silently eaten by the WPF dispatcher. Always wrap in try-catch with file-based error logging.

---

## Complete Working Example

```csharp
using System;
using System.Windows;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using WinForms = System.Windows.Forms;
using Application = System.Windows.Application;
using StartupEventArgs = System.Windows.StartupEventArgs;
using ExitEventArgs = System.Windows.ExitEventArgs;

namespace MyWpfApp
{
    public partial class App : Application
    {
        private WinForms.NotifyIcon _notifyIcon;
        private IHost _host;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            // Create tray icon synchronously
            _notifyIcon = new WinForms.NotifyIcon
            {
                Text = "My App",
                Icon = System.Drawing.SystemIcons.Application,
                ContextMenuStrip = BuildMenu(),
                Visible = true
            };

            // Build DI host in background
            Task.Run(async () =>
            {
                _host = Host.CreateDefaultBuilder()
                    .ConfigureServices((context, services) =>
                    {
                        services.AddSingleton<IMyService, MyService>();
                    })
                    .Build();

                await _host.StartAsync();
            });
        }

        private WinForms.ContextMenuStrip BuildMenu()
        {
            var menu = new WinForms.ContextMenuStrip();

            var showItem = new WinForms.ToolStripMenuItem("Show Window");
            showItem.Click += (s, e) => { /* Show main window */ };
            menu.Items.Add(showItem);

            menu.Items.Add(new WinForms.ToolStripSeparator());

            var exitItem = new WinForms.ToolStripMenuItem("Exit");
            exitItem.Click += (s, e) =>
            {
                _notifyIcon.Visible = false;
                _notifyIcon.Dispose();
                Current.Shutdown();
            };
            menu.Items.Add(exitItem);

            return menu;
        }

        protected override void OnExit(ExitEventArgs e)
        {
            _notifyIcon?.Dispose();
            _host?.StopAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
            _host?.Dispose();
            base.OnExit(e);
        }
    }
}
```

---

## Summary: The Working Recipe

1. **Enable WinForms**: `<UseWindowsForms>true</UseWindowsForms>` in your `.csproj`
2. **Add type aliases**: Resolve namespace collisions between WPF and WinForms
3. **Create tray icon synchronously**: In `OnStartup`, before any `async` operations
4. **Build Generic Host in background**: Use `Task.Run(() => builder.Build())` if using DI
5. **Dispose properly**: Set `Visible = false` before disposing the NotifyIcon

This pattern has been battle-tested on .NET 8 WPF applications and works flawlessly.
