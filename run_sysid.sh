#!/usr/bin/env bash
# Launch SysId acrobot experiment + Dash UI together.
# Usage: ./run_sysid.sh
# Requires: vcan0 & vcan2 interfaces up, AcrobatSim.jl/dash/.venv with deps installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="/home/aditya/Desktop/SRT/AcrobatSim.jl/dash/.venv"

# ── Check vcan interfaces ──────────────────────────────────────────────
for iface in vcan0 vcan2; do
    if ! ip link show "$iface" &>/dev/null; then
        echo "ERROR: $iface not found. Run: sudo bash J1939Parser.jl/logs/setupVirtualCAN.sh"
        exit 1
    fi
done
echo "✓ vcan0 and vcan2 are up"

# ── Free ports 8060, 9200, 9201 if already in use ─────────────────────
for port in 8060 9200 9201; do
    pids=$(ss -tlnp | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | sort -u || true)
    if [ -n "$pids" ]; then
        echo "Killing processes on port $port: $pids"
        for pid in $pids; do
            kill "$pid" 2>/dev/null || true
        done
    fi
done
sleep 1
echo "✓ Ports 8060, 9200, 9201 are free"

# ── Start Julia SysId experiment in background ────────────────────────
echo "Starting SysId experiment..."
cd "$SCRIPT_DIR"
julia --threads=auto --project=. examples/acrobot_sysid.jl &
JULIA_PID=$!
echo "  Julia PID: $JULIA_PID"

# Wait for TcpMonitor to be listening on port 9200 before starting Dash
echo "Waiting for TcpMonitor (port 9200)..."
for i in $(seq 1 60); do
    if ss -tln | grep -q ':9200 '; then
        echo "✓ TcpMonitor ready on port 9200"
        break
    fi
    if ! kill -0 "$JULIA_PID" 2>/dev/null; then
        echo "ERROR: Julia process exited unexpectedly"
        exit 1
    fi
    sleep 1
done

if ! ss -tln | grep -q ':9200 '; then
    echo "ERROR: TcpMonitor did not start within 60s"
    kill "$JULIA_PID" 2>/dev/null || true
    exit 1
fi

# ── Start Dash UI using AcrobatSim's venv ─────────────────────────────
echo "Starting Dash UI on port 8060..."
source "$VENV/bin/activate"
PYTHONPATH="$SCRIPT_DIR/../srt-dash${PYTHONPATH:+:$PYTHONPATH}" python "$SCRIPT_DIR/dash/app.py" &
DASH_PID=$!
echo "  Dash PID: $DASH_PID"

echo "Waiting for Dash UI (port 8060)..."
for i in $(seq 1 20); do
    if ss -tln | grep -q ':8060 '; then
        echo "✓ Dash UI ready on port 8060"
        break
    fi
    if ! kill -0 "$DASH_PID" 2>/dev/null; then
        echo "ERROR: Dash process exited unexpectedly"
        kill "$JULIA_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

if ! ss -tln | grep -q ':8060 '; then
    echo "ERROR: Dash UI did not start within 20s"
    kill "$DASH_PID" 2>/dev/null || true
    kill "$JULIA_PID" 2>/dev/null || true
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  SysId running"
echo "  Dash UI:  http://localhost:8060"
echo "  Params:   TCP port 9200"
echo "  Stream:   TCP port 9201"
echo "═══════════════════════════════════════════"
echo "  Press Ctrl+C to stop both processes"
echo ""

# ── Cleanup on exit ───────────────────────────────────────────────────
cleanup() {
    echo ""
    echo "Shutting down..."
    kill "$DASH_PID" 2>/dev/null || true
    kill "$JULIA_PID" 2>/dev/null || true
    wait "$DASH_PID" 2>/dev/null || true
    wait "$JULIA_PID" 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT INT TERM

# Wait for Julia (the long-running process)
wait "$JULIA_PID" 2>/dev/null || true
