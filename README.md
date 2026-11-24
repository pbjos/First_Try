# Router slowdown check

Two read-only scripts that check your home network for common causes of slowness: Wi-Fi signal and channel crowding, latency and packet loss, DNS speed, upload and download speed, lag when the line is busy (bufferbloat), interface errors, and the devices on your network.

Run one from a computer on your home network. If you can, run it once over Wi-Fi and once with a cable plugged into the router, so you can tell a Wi-Fi problem from a router or internet problem.

- **macOS / Linux:** `bash router-check.sh`
- **Windows (PowerShell):** `powershell -ExecutionPolicy Bypass -File .\router-check.ps1`

It takes about 2–3 minutes and uses about 150 MB of data for the speed tests. The results are saved to `router-report-<date>.txt` in the current folder.

The report shortens MAC addresses to their manufacturer part and leaves out Wi-Fi network names. It still contains your local IP addresses, so look it over before you share it.
