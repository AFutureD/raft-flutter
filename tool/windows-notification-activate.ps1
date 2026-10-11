# Native protocol smoke: invoke the lab's COM callback, never a production GUID.
# This verifies Windows COM activation; it does not simulate a UI/toast click.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("53E31837-6600-4A81-9395-75CFFE746F94"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface INotificationActivationCallback {
    void Activate([MarshalAs(UnmanagedType.LPWStr)] string appId,
                  [MarshalAs(UnmanagedType.LPWStr)] string arguments,
                  IntPtr data, uint count);
}

public static class RaftNotificationLabActivation {
    [DllImport("ole32.dll", PreserveSig = false)]
    static extern void CoCreateInstance(ref Guid clsid, IntPtr outer,
        uint context, ref Guid iid, [MarshalAs(UnmanagedType.Interface)]
        out INotificationActivationCallback callback);
    public static void Run() {
        var clsid = new Guid("c7f8c268-2e7c-5079-9305-1a7294c70d9d");
        var iid = new Guid("53E31837-6600-4A81-9395-75CFFE746F94");
        INotificationActivationCallback instance;
        CoCreateInstance(ref clsid, IntPtr.Zero, 4, ref iid, out instance);
        try {
            instance.Activate(
                "app.raft.raft_flutter.notificationlab",
                "raft-notification-test", IntPtr.Zero, 0);
        } finally {
            Marshal.ReleaseComObject(instance);
        }
    }
}
'@
[RaftNotificationLabActivation]::Run()
