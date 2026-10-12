using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Native
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetShellWindow();
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("gdi32.dll", SetLastError = true)]
    public static extern bool DeleteObject(IntPtr hObject);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetParent(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);

    public const uint WM_SPAWN_WORKER = 0x052C;
    public const uint SMTO_NORMAL = 0x0000;

    /// <summary>
    /// 找一个可以承载"桌面挂件"的宿主窗口。
    ///
    /// 桌面层级有两种常见结构, 都要兼容:
    ///   ① Progman -> SHELLDLL_DefView            (Win11 常见; 实测目标机器就是这种)
    ///   ② WorkerW -> SHELLDLL_DefView + 同级 WorkerW  (Win10 及部分 Win11)
    ///
    /// 优先返回 Progman: SHELLDLL_DefView 是 WS_EX_LAYERED 窗口, 把子窗口挂到它上面
    /// 在部分系统上不渲染; 挂到 Progman 则稳定, 且天然位于图标层之上。
    /// 找不到就返回 IntPtr.Zero, 调用方应退回普通顶层窗口模式。
    /// </summary>
    public static IntPtr FindDesktopHost()
    {
        // GetShellWindow 比 FindWindow("Progman") 可靠: 后者受调用进程 DPI 感知上下文影响, 实测会返回 0
        IntPtr progman = GetShellWindow();
        if (progman == IntPtr.Zero) progman = FindWindow("Progman", null);
        if (progman != IntPtr.Zero)
        {
            // 触发 Progman 派生出承载壁纸的 WorkerW(部分系统需要)
            IntPtr res;
            SendMessageTimeout(progman, WM_SPAWN_WORKER, new IntPtr(0xD), new IntPtr(0x1), SMTO_NORMAL, 1000, out res);

            // 结构①: 图标层直接挂在 Progman 下 -> 就用 Progman
            if (FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero)
            {
                return progman;
            }
        }

        // 结构②: 图标层挂在某个 WorkerW 下 -> 用它的同级 WorkerW 作为可绘制层
        IntPtr worker = FindWindowEx(IntPtr.Zero, IntPtr.Zero, "WorkerW", null);
        while (worker != IntPtr.Zero)
        {
            if (FindWindowEx(worker, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero)
            {
                IntPtr sibling = FindWindowEx(IntPtr.Zero, worker, "WorkerW", null);
                return sibling != IntPtr.Zero ? sibling : worker;
            }
            worker = FindWindowEx(IntPtr.Zero, worker, "WorkerW", null);
        }

        // 兜底: 至少还有 Progman
        return progman;
    }

    public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct AccentPolicy
    {
        public int AccentState;
        public int AccentFlags;
        public int GradientColor;
        public int AnimationId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WindowCompositionAttributeData
    {
        public int Attribute;
        public IntPtr Data;
        public int SizeOfData;
    }

    public const int WH_KEYBOARD_LL = 13;
    public const int WM_KEYDOWN = 0x0100;
    public const int WM_SYSKEYDOWN = 0x0104;

    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_NOOWNERZORDER = 0x0200;

    public static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
    public static readonly IntPtr HWND_TOP = IntPtr.Zero;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    public const int GWL_EXSTYLE = -20;
    public const int GWL_STYLE = -16;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_LAYERED = 0x00080000;
    // 挂载为桌面子窗口需要: 先清 WS_POPUP 再设 WS_CHILD, 否则跨进程 SetParent 会返回错误 5
    public const int WS_CHILD = 0x40000000;
    public const int WS_POPUP = unchecked((int)0x80000000);

    // SetWindowCompositionAttribute 的属性号与状态值
    public const int WCA_ACCENT_POLICY = 19;
    public const int ACCENT_DISABLED = 0;
    public const int ACCENT_ENABLE_BLURBEHIND = 3;
    public const int ACCENT_ENABLE_ACRYLICBLURBEHIND = 4;

    /// <summary>
    /// 只加 TOOLWINDOW(不进任务栏/Alt+Tab), 不加 NOACTIVATE。
    /// NOACTIVATE 会让窗口永远拿不到键盘输入, 搜索框就没法用, 因此去掉。
    /// </summary>
    public static void MakeToolWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        ex |= WS_EX_TOOLWINDOW;
        ex &= ~WS_EX_NOACTIVATE;
        ex &= ~WS_EX_LAYERED;   // 亚克力模糊要求不使用分层窗口
        SetWindowLong(hwnd, GWL_EXSTYLE, ex);
    }

    /// <summary>
    /// 高斯玻璃(亚克力)背景。优先用 ACRYLICBLURBEHIND(高斯模糊+噪声, 观感最好),
    /// 不支持时退回 BLURBEHIND。
    /// tint 为 0xAARRGGBB, 其 A 通道决定染色强度, 窗口背景需半透明才能透出模糊层。
    /// </summary>
    public static bool ApplyGlass(IntPtr hwnd, int tint, bool acrylic)
    {
        if (hwnd == IntPtr.Zero) return false;
        return Apply(hwnd, acrylic ? ACCENT_ENABLE_ACRYLICBLURBEHIND : ACCENT_ENABLE_BLURBEHIND, tint);
    }

    public static bool ApplyBlurOnly(IntPtr hwnd, int tint)
    {
        return Apply(hwnd, ACCENT_ENABLE_BLURBEHIND, tint);
    }

    private static bool Apply(IntPtr hwnd, int state, int tint)
    {
        try
        {
            AccentPolicy policy = new AccentPolicy();
            policy.AccentState = state;
            policy.AccentFlags = 2;      // 四边都生效
            policy.GradientColor = tint; // 0xAABBGGRR 字节序, 调用方按此传入
            policy.AnimationId = 0;

            int size = Marshal.SizeOf(policy);
            IntPtr ptr = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(policy, ptr, false);
                WindowCompositionAttributeData data = new WindowCompositionAttributeData();
                data.Attribute = WCA_ACCENT_POLICY;
                data.Data = ptr;
                data.SizeOfData = size;
                int hr = SetWindowCompositionAttribute(hwnd, ref data);
                return hr != 0;
            }
            finally { Marshal.FreeHGlobal(ptr); }
        }
        catch { return false; }
    }

    /// <summary>关闭玻璃效果。</summary>
    public static void ClearGlass(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        Apply(hwnd, ACCENT_DISABLED, 0);
    }

    /// <summary>压到最底层(仅高于桌面), 普通窗口能自然盖住它。</summary>
    public static void SendToBottom(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }

    /// <summary>
    /// 只移动/改尺寸, 用 HWND_TOPMOST 保持置顶。
    /// 注意: hWndInsertAfter 传 IntPtr.Zero(=HWND_TOP) 会摘掉 WS_EX_TOPMOST, 窗口会被别的窗口盖住。
    /// </summary>
    public static void MoveKeepTop(IntPtr hwnd, int x, int y, int w, int h)
    {
        if (hwnd == IntPtr.Zero) return;
        // 用 HWND_TOP 而不是 HWND_TOPMOST: 子窗口再设 WS_EX_TOPMOST 会让坐标解释出错
        // (实测请求 (1806,987) 却落到 (152,152))。
        SetWindowPos(hwnd, HWND_TOP, x, y, w, h, SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }

    /// <summary>
    /// 定位到指定物理坐标, 并压到 z 序最底(贴桌面)。
    /// 这是"只在桌面"的可靠做法: 不用 SetParent —— 实测把窗口挂到 Progman 虽然
    /// SetParent/GetParent 都成功, 但窗口不渲染(SHELLDLL_DefView 是 WS_EX_LAYERED,
    /// 本机 DWM 分层合成对子窗口不可靠)。
    /// 代价: 最大化的应用会盖住它 —— 这正是"待在桌面"应有的行为。
    /// </summary>
    public static void MoveToBottom(IntPtr hwnd, int x, int y, int w, int h)
    {
        if (hwnd == IntPtr.Zero) return;
        SetWindowPos(hwnd, HWND_BOTTOM, x, y, w, h, SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }

    /// <summary>抬到最前: 只改 z 序, 不动位置尺寸。</summary>
    public static void RaiseToFront(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }
}
