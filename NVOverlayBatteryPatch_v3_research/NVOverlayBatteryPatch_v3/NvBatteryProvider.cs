using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Management;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

namespace NVOverlayBatteryPatch
{
    internal sealed class BatterySnapshot
    {
        public double Percent = -1;
        public double Watts = double.NaN;
        public double TemperatureC = double.NaN;
        public int Minutes = -1;
        public bool Charging = false;
        public bool Discharging = false;
        public bool PluggedIn = false;
        public string Display = "N/A";
    }

    internal static class Program
    {
        private const int Port = 37921;
        private const string PatchMarker = "NVBO_PATCH_V3";
        private const string RepairTaskName = "NVOverlayBatteryPatch";
        private static readonly object CacheLock = new object();
        private static string CachedJson = "{\"display\":\"N/A\"}";
        private static readonly Queue<double> RateHistory = new Queue<double>();
        private static int LastRateSign = 0;
        private static readonly object GpuLock = new object();
        private static double CachedGpuTempC = double.NaN;
        private static string CachedGpuState = "N/A";
        private static DateTime LastGpuProbeUtc = DateTime.MinValue;
        private static readonly object RepairLock = new object();
        private static DateTime LastOscEventUtc = DateTime.MinValue;
        private static DateTime LastPeriodicCheckUtc = DateTime.MinValue;
        private static DateTime LastRepairAttemptUtc = DateTime.MinValue;
        private static string LastRepairSignature = "";
        private static bool OscChangePending = false;
        private static FileSystemWatcher OscWatcher;

        [STAThread]
        private static void Main()
        {
            bool createdNew;
            using (Mutex mutex = new Mutex(true, @"Local\NVOverlayBatteryProvider", out createdNew))
            {
                if (!createdNew)
                    return;

                Thread sampleThread = new Thread(SampleLoop);
                sampleThread.IsBackground = true;
                sampleThread.Start();

                StartOverlayWatcher();

                Thread repairThread = new Thread(RepairLoop);
                repairThread.IsBackground = true;
                repairThread.Start();

                RunServer();
            }
        }

        private static void SampleLoop()
        {
            while (true)
            {
                try
                {
                    BatterySnapshot snapshot = ReadBattery();
                    ProbeGpuTemperature();
                    string json = BuildJson(snapshot);
                    lock (CacheLock)
                    {
                        CachedJson = json;
                    }
                }
                catch
                {
                    lock (CacheLock)
                    {
                        CachedJson = "{\"display\":\"N/A\"}";
                    }
                }

                Thread.Sleep(2000);
            }
        }

        private static BatterySnapshot ReadBattery()
        {
            BatterySnapshot b = new BatterySnapshot();

            double remaining = 0;
            double full = 0;
            double chargeRate = 0;
            double dischargeRate = 0;
            bool haveRemaining = false;
            bool haveFull = false;
            bool haveWmiStatus = false;
            bool powerOnline = false;

            try
            {
                ManagementScope scope = new ManagementScope(@"\\.\root\WMI");
                scope.Connect();

                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT * FROM BatteryStatus")))
                using (ManagementObjectCollection results = searcher.Get())
                {
                    foreach (ManagementObject mo in results)
                    {
                        haveWmiStatus = true;

                        double v = GetDouble(mo, "RemainingCapacity");
                        if (v >= 0)
                        {
                            remaining += v;
                            haveRemaining = true;
                        }

                        v = GetDouble(mo, "ChargeRate");
                        if (v > 0)
                            chargeRate += v;

                        v = GetDouble(mo, "DischargeRate");
                        if (v > 0)
                            dischargeRate += v;

                        bool? online = GetBool(mo, "PowerOnline");
                        if (online.HasValue && online.Value)
                            powerOnline = true;
                    }
                }

                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT * FROM BatteryFullChargedCapacity")))
                using (ManagementObjectCollection results = searcher.Get())
                {
                    foreach (ManagementObject mo in results)
                    {
                        double v = GetDouble(mo, "FullChargedCapacity");
                        if (v > 0)
                        {
                            full += v;
                            haveFull = true;
                        }
                    }
                }

                try
                {
                    double tempSum = 0;
                    int tempCount = 0;
                    using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT * FROM BatteryTemperature")))
                    using (ManagementObjectCollection results = searcher.Get())
                    {
                        foreach (ManagementObject mo in results)
                        {
                            double raw = GetDouble(mo, "Temperature");
                            double c = double.NaN;

                            if (raw > 1000 && raw < 5000)
                                c = (raw / 10.0) - 273.15;
                            else if (raw > -30 && raw < 120)
                                c = raw;

                            if (!double.IsNaN(c) && c > -20 && c < 100)
                            {
                                tempSum += c;
                                tempCount++;
                            }
                        }
                    }

                    if (tempCount > 0)
                        b.TemperatureC = tempSum / tempCount;
                }
                catch
                {
                }
            }
            catch
            {
            }

            PowerStatus ps = SystemInformation.PowerStatus;
            b.PluggedIn = powerOnline || ps.PowerLineStatus == PowerLineStatus.Online;

            if (haveRemaining && haveFull && full > 0)
                b.Percent = Math.Max(0, Math.Min(100, remaining * 100.0 / full));
            else if (ps.BatteryLifePercent >= 0)
                b.Percent = Math.Max(0, Math.Min(100, ps.BatteryLifePercent * 100.0));

            double rawWatts = double.NaN;

            if (chargeRate > 0 && b.PluggedIn)
            {
                rawWatts = chargeRate / 1000.0;
                b.Charging = true;
            }
            else if (dischargeRate > 0 && !b.PluggedIn)
            {
                rawWatts = -(dischargeRate / 1000.0);
                b.Discharging = true;
            }
            else if (dischargeRate > 0 && chargeRate <= 0)
            {
                rawWatts = -(dischargeRate / 1000.0);
                b.Discharging = true;
            }
            else if (chargeRate > 0)
            {
                rawWatts = chargeRate / 1000.0;
                b.Charging = true;
            }

            if (!double.IsNaN(rawWatts) && Math.Abs(rawWatts) > 0.02 && Math.Abs(rawWatts) < 1000)
                b.Watts = SmoothRate(rawWatts);

            if (b.Charging && haveRemaining && haveFull && chargeRate > 0 && full > remaining)
            {
                double h = (full - remaining) / chargeRate;
                if (h >= 0 && h < 240)
                    b.Minutes = (int)Math.Round(h * 60.0);
            }
            else if (b.Discharging && haveRemaining && dischargeRate > 0)
            {
                double h = remaining / dischargeRate;
                if (h >= 0 && h < 240)
                    b.Minutes = (int)Math.Round(h * 60.0);
            }
            else if (!b.PluggedIn && ps.BatteryLifeRemaining > 0)
            {
                b.Discharging = true;
                b.Minutes = (int)Math.Round(ps.BatteryLifeRemaining / 60.0);
            }

            if (b.Percent < 0)
            {
                try
                {
                    using (ManagementObjectSearcher s = new ManagementObjectSearcher("SELECT EstimatedChargeRemaining, EstimatedRunTime, BatteryStatus FROM Win32_Battery"))
                    using (ManagementObjectCollection r = s.Get())
                    {
                        foreach (ManagementObject mo in r)
                        {
                            double pct = GetDouble(mo, "EstimatedChargeRemaining");
                            if (pct >= 0)
                                b.Percent = Math.Max(0, Math.Min(100, pct));

                            double runtime = GetDouble(mo, "EstimatedRunTime");
                            if (b.Minutes < 0 && runtime > 0 && runtime < 1000000)
                                b.Minutes = (int)Math.Round(runtime);
                            break;
                        }
                    }
                }
                catch
                {
                }
            }

            b.Display = BuildDisplay(b);
            return b;
        }

        private static double SmoothRate(double raw)
        {
            int sign = raw > 0 ? 1 : -1;
            lock (RateHistory)
            {
                if (sign != LastRateSign)
                {
                    RateHistory.Clear();
                    LastRateSign = sign;
                }

                RateHistory.Enqueue(raw);
                while (RateHistory.Count > 10)
                    RateHistory.Dequeue();

                double sum = 0;
                foreach (double x in RateHistory)
                    sum += x;

                return sum / RateHistory.Count;
            }
        }

        private static string BuildDisplay(BatterySnapshot b)
        {
            if (b.Percent < 0)
                return "N/A";

            string text = "BAT " + Math.Round(b.Percent).ToString("0", CultureInfo.InvariantCulture) + "%";

            if (!double.IsNaN(b.TemperatureC))
                text += " " + b.TemperatureC.ToString("0", CultureInfo.InvariantCulture) + "\u00B0C";

            if (!double.IsNaN(b.Watts))
            {
                if (b.Watts > 0)
                    text += " \u2191" + Math.Abs(b.Watts).ToString("0.0", CultureInfo.InvariantCulture) + "W";
                else
                    text += " \u2193" + Math.Abs(b.Watts).ToString("0.0", CultureInfo.InvariantCulture) + "W";
            }
            else if (b.PluggedIn)
            {
                text += " AC";
            }

            if (b.Minutes >= 0)
                text += " " + FormatMinutes(b.Minutes);

            return text;
        }

        private static string FormatMinutes(int minutes)
        {
            if (minutes < 0)
                return "";
            int h = minutes / 60;
            int m = minutes % 60;
            return h.ToString(CultureInfo.InvariantCulture) + ":" + m.ToString("00", CultureInfo.InvariantCulture);
        }

        private static string BuildJson(BatterySnapshot b)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("{");
            sb.Append("\"providerVersion\":\"3.0.0\",");
            sb.Append("\"display\":\"").Append(JsonEscape(b.Display)).Append("\"");
            if (b.Percent >= 0)
                sb.Append(",\"percent\":").Append(b.Percent.ToString("0.0", CultureInfo.InvariantCulture));
            if (!double.IsNaN(b.Watts))
                sb.Append(",\"watts\":").Append(b.Watts.ToString("0.00", CultureInfo.InvariantCulture));
            if (!double.IsNaN(b.TemperatureC))
                sb.Append(",\"temperatureC\":").Append(b.TemperatureC.ToString("0.0", CultureInfo.InvariantCulture));
            if (b.Minutes >= 0)
                sb.Append(",\"minutes\":").Append(b.Minutes.ToString(CultureInfo.InvariantCulture));
            sb.Append(",\"charging\":").Append(b.Charging ? "true" : "false");
            sb.Append(",\"discharging\":").Append(b.Discharging ? "true" : "false");
            sb.Append(",\"pluggedIn\":").Append(b.PluggedIn ? "true" : "false");
            lock (GpuLock)
            {
                if (!double.IsNaN(CachedGpuTempC))
                    sb.Append(",\"gpuTempC\":").Append(CachedGpuTempC.ToString("0.0", CultureInfo.InvariantCulture));
                sb.Append(",\"gpuState\":\"").Append(JsonEscape(CachedGpuState)).Append("\"");
            }
            sb.Append("}");
            return sb.ToString();
        }

        private static void ProbeGpuTemperature()
        {
            lock (GpuLock)
            {
                if ((DateTime.UtcNow - LastGpuProbeUtc).TotalSeconds < 5)
                    return;
                LastGpuProbeUtc = DateTime.UtcNow;
            }

            double temp = double.NaN;
            string state = "N/A";

            try
            {
                temp = TryReadGpuTempNvml();
                if (!double.IsNaN(temp))
                    state = "ACTIVE";
            }
            catch
            {
            }

            if (double.IsNaN(temp))
            {
                try
                {
                    temp = TryReadGpuTempNvidiaSmi(out state);
                }
                catch
                {
                    temp = double.NaN;
                    state = "N/A";
                }
            }

            lock (GpuLock)
            {
                CachedGpuTempC = temp;
                CachedGpuState = state;
            }
        }

        private static double TryReadGpuTempNvml()
        {
            int rc;
            try
            {
                rc = NvmlNative.nvmlInit_v2();
            }
            catch (DllNotFoundException)
            {
                return double.NaN;
            }
            catch (EntryPointNotFoundException)
            {
                return double.NaN;
            }

            if (rc != 0)
                return double.NaN;

            try
            {
                uint count;
                if (NvmlNative.nvmlDeviceGetCount_v2(out count) != 0 || count == 0)
                    return double.NaN;

                double best = double.NaN;
                for (uint i = 0; i < count; i++)
                {
                    IntPtr dev;
                    if (NvmlNative.nvmlDeviceGetHandleByIndex_v2(i, out dev) != 0 || dev == IntPtr.Zero)
                        continue;

                    uint t;
                    if (NvmlNative.nvmlDeviceGetTemperature(dev, 0, out t) == 0 && t > 0 && t < 130)
                    {
                        if (double.IsNaN(best) || t > best)
                            best = t;
                    }
                }
                return best;
            }
            finally
            {
                try { NvmlNative.nvmlShutdown(); } catch { }
            }
        }

        private static double TryReadGpuTempNvidiaSmi(out string state)
        {
            state = "N/A";
            string exe = Path.Combine(Environment.SystemDirectory, "nvidia-smi.exe");
            if (!File.Exists(exe))
            {
                string alt = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"NVIDIA Corporation\NVSMI\nvidia-smi.exe");
                exe = File.Exists(alt) ? alt : "nvidia-smi.exe";
            }

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = exe;
            psi.Arguments = "--query-gpu=temperature.gpu --format=csv,noheader,nounits";
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;

            using (Process p = Process.Start(psi))
            {
                if (p == null)
                    return double.NaN;

                string output = p.StandardOutput.ReadToEnd();
                if (!p.WaitForExit(2500))
                {
                    try { p.Kill(); } catch { }
                    state = "OFF";
                    return double.NaN;
                }

                double best = double.NaN;
                string[] lines = output.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                foreach (string raw in lines)
                {
                    string line = raw.Trim();
                    double t;
                    if (double.TryParse(line, NumberStyles.Float, CultureInfo.InvariantCulture, out t) && t > 0 && t < 130)
                    {
                        if (double.IsNaN(best) || t > best)
                            best = t;
                    }
                }

                if (!double.IsNaN(best))
                    state = "ACTIVE";
                else
                    state = "OFF";
                return best;
            }
        }

        private static class NvmlNative
        {
            [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
            internal static extern int nvmlInit_v2();

            [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
            internal static extern int nvmlShutdown();

            [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
            internal static extern int nvmlDeviceGetCount_v2(out uint deviceCount);

            [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
            internal static extern int nvmlDeviceGetHandleByIndex_v2(uint index, out IntPtr device);

            [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
            internal static extern int nvmlDeviceGetTemperature(IntPtr device, uint sensorType, out uint temp);
        }

        private static string JsonEscape(string s)
        {
            if (s == null)
                return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "\\n");
        }

        private static double GetDouble(ManagementBaseObject o, string name)
        {
            try
            {
                PropertyData p = o.Properties[name];
                if (p == null || p.Value == null)
                    return -1;
                return Convert.ToDouble(p.Value, CultureInfo.InvariantCulture);
            }
            catch
            {
                return -1;
            }
        }

        private static bool? GetBool(ManagementBaseObject o, string name)
        {
            try
            {
                PropertyData p = o.Properties[name];
                if (p == null || p.Value == null)
                    return null;
                return Convert.ToBoolean(p.Value, CultureInfo.InvariantCulture);
            }
            catch
            {
                return null;
            }
        }

        private static void RunServer()
        {
            while (true)
            {
                TcpListener listener = null;
                try
                {
                    listener = new TcpListener(IPAddress.Loopback, Port);
                    listener.Start(16);

                    while (true)
                    {
                        using (TcpClient client = listener.AcceptTcpClient())
                        {
                            HandleClient(client);
                        }
                    }
                }
                catch
                {
                    try
                    {
                        if (listener != null)
                            listener.Stop();
                    }
                    catch
                    {
                    }
                    Thread.Sleep(5000);
                }
            }
        }

        private static void HandleClient(TcpClient client)
        {
            try
            {
                client.ReceiveTimeout = 2000;
                client.SendTimeout = 2000;
                NetworkStream stream = client.GetStream();

                byte[] requestBuffer = new byte[4096];
                int read = 0;
                try
                {
                    read = stream.Read(requestBuffer, 0, requestBuffer.Length);
                }
                catch
                {
                }

                string request = read > 0 ? Encoding.ASCII.GetString(requestBuffer, 0, read) : "";
                bool isOptions = request.StartsWith("OPTIONS ", StringComparison.OrdinalIgnoreCase);

                string body;
                lock (CacheLock)
                {
                    body = CachedJson;
                }

                byte[] bodyBytes = isOptions ? new byte[0] : Encoding.UTF8.GetBytes(body);

                StringBuilder headers = new StringBuilder();
                headers.Append("HTTP/1.1 200 OK\r\n");
                headers.Append("Content-Type: application/json; charset=utf-8\r\n");
                headers.Append("Access-Control-Allow-Origin: *\r\n");
                headers.Append("Access-Control-Allow-Methods: GET, OPTIONS\r\n");
                headers.Append("Access-Control-Allow-Headers: *\r\n");
                headers.Append("Access-Control-Allow-Private-Network: true\r\n");
                headers.Append("Cache-Control: no-store, no-cache, must-revalidate\r\n");
                headers.Append("Connection: close\r\n");
                headers.Append("Content-Length: ").Append(bodyBytes.Length.ToString(CultureInfo.InvariantCulture)).Append("\r\n\r\n");

                byte[] headerBytes = Encoding.ASCII.GetBytes(headers.ToString());
                stream.Write(headerBytes, 0, headerBytes.Length);
                if (bodyBytes.Length > 0)
                    stream.Write(bodyBytes, 0, bodyBytes.Length);
                stream.Flush();
            }
            catch
            {
            }
        }

        private static string GetOscDirectory()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                @"NVIDIA Corporation\NVIDIA App\osc");
        }

        private static void StartOverlayWatcher()
        {
            try
            {
                string osc = GetOscDirectory();
                if (!Directory.Exists(osc))
                    return;

                OscWatcher = new FileSystemWatcher(osc, "*");
                OscWatcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite |
                                          NotifyFilters.Size | NotifyFilters.CreationTime;
                OscWatcher.Changed += delegate(object sender, FileSystemEventArgs e) { MarkOscChangeIfRelevant(e.FullPath); };
                OscWatcher.Created += delegate(object sender, FileSystemEventArgs e) { MarkOscChangeIfRelevant(e.FullPath); };
                OscWatcher.Deleted += delegate(object sender, FileSystemEventArgs e) { MarkOscChangeIfRelevant(e.FullPath); };
                OscWatcher.Renamed += delegate(object sender, RenamedEventArgs e) { MarkOscChangeIfRelevant(e.FullPath); };
                OscWatcher.EnableRaisingEvents = true;
            }
            catch
            {
            }
        }

        private static void MarkOscChangeIfRelevant(string path)
        {
            try
            {
                string name = Path.GetFileName(path);
                if (!name.Equals("index.html", StringComparison.OrdinalIgnoreCase) &&
                    !(name.StartsWith("main.", StringComparison.OrdinalIgnoreCase) &&
                      name.EndsWith(".js", StringComparison.OrdinalIgnoreCase)))
                    return;
            }
            catch
            {
                return;
            }

            lock (RepairLock)
            {
                LastOscEventUtc = DateTime.UtcNow;
                OscChangePending = true;
            }
        }

        private static void RepairLoop()
        {
            // Let NVIDIA App and Windows finish their normal logon startup first.
            Thread.Sleep(15000);

            while (true)
            {
                try
                {
                    bool shouldCheck = false;
                    DateTime now = DateTime.UtcNow;

                    lock (RepairLock)
                    {
                        // Debounce filesystem events so an NVIDIA update can finish writing its files.
                        if (OscChangePending && (now - LastOscEventUtc).TotalSeconds >= 30)
                        {
                            OscChangePending = false;
                            shouldCheck = true;
                        }

                        // Fallback polling in case FileSystemWatcher misses an event.
                        if ((now - LastPeriodicCheckUtc).TotalMinutes >= 5)
                        {
                            LastPeriodicCheckUtc = now;
                            shouldCheck = true;
                        }
                    }

                    if (shouldCheck)
                        CheckPatchAndRepair();
                }
                catch
                {
                }

                Thread.Sleep(5000);
            }
        }

        private static string GetActiveMainFile(string osc)
        {
            try
            {
                string index = Path.Combine(osc, "index.html");
                if (File.Exists(index))
                {
                    string html = File.ReadAllText(index);
                    Match m = Regex.Match(html, @"main\.[A-Za-z0-9._-]+\.js", RegexOptions.IgnoreCase);
                    if (m.Success)
                    {
                        string candidate = Path.Combine(osc, m.Value);
                        if (File.Exists(candidate))
                            return candidate;
                    }
                }
            }
            catch
            {
            }

            string[] files = Directory.GetFiles(osc, "main.*.js", SearchOption.TopDirectoryOnly);
            if (files.Length == 0)
                return null;

            string newest = files[0];
            DateTime newestTime = File.GetLastWriteTimeUtc(newest);
            for (int i = 1; i < files.Length; i++)
            {
                DateTime t = File.GetLastWriteTimeUtc(files[i]);
                if (t > newestTime)
                {
                    newest = files[i];
                    newestTime = t;
                }
            }
            return newest;
        }

        private static void CheckPatchAndRepair()
        {
            string osc = GetOscDirectory();
            if (!Directory.Exists(osc))
                return;

            string newest = GetActiveMainFile(osc);
            if (string.IsNullOrEmpty(newest))
                return;

            string content;
            try
            {
                content = File.ReadAllText(newest);
            }
            catch
            {
                return;
            }

            if (content.IndexOf(PatchMarker, StringComparison.Ordinal) >= 0)
                return;

            FileInfo fi = new FileInfo(newest);
            string signature = newest + "|" + fi.Length.ToString(CultureInfo.InvariantCulture) + "|" +
                               fi.LastWriteTimeUtc.Ticks.ToString(CultureInfo.InvariantCulture);

            lock (RepairLock)
            {
                // Do not hammer the elevated repair task when a completely new NVIDIA version
                // is not compatible with the current safe patch profile.
                if (signature == LastRepairSignature &&
                    (DateTime.UtcNow - LastRepairAttemptUtc).TotalHours < 6)
                    return;

                LastRepairSignature = signature;
                LastRepairAttemptUtc = DateTime.UtcNow;
            }

            RunRepairTask();
        }

        private static void RunRepairTask()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "schtasks.exe");
                psi.Arguments = "/Run /TN \"" + RepairTaskName + "\"";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                Process.Start(psi);
            }
            catch
            {
            }
        }
    }
}
