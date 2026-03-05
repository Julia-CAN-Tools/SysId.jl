#!/usr/bin/env bash
# Master launcher: AcrobotSim (plant) + SysId (experiment) + both Dash UIs.
#
# Usage: ./run_acrobot_sysid.sh
#
# Starts:
#   1. AcrobotSim.jl — plant simulator on vcan0/vcan2, Dash on port 8050
#   2. SysId.jl      — excitation + logging,           Dash on port 8060
#
# Requires: vcan0 & vcan2 interfaces up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ACROBAT_DIR="$SRT_DIR/AcrobatSim.jl"
SYSID_DIR="$SRT_DIR/SysId.jl"
VENV="$ACROBAT_DIR/dash/.venv"

# ── Check prerequisites ──────────────────────────────────────────────
for iface in vcan0 vcan2; do
    if ! ip link show "$iface" &>/dev/null; then
        echo "ERROR: $iface not found. Run: sudo bash J1939Parser.jl/logs/setupVirtualCAN.sh"
        exit 1
    fi
done
echo "✓ vcan0 and vcan2 are up"

if [ ! -f "$VENV/bin/activate" ]; then
    echo "ERROR: Python venv not found at $VENV"
    echo "  Create it: cd $ACROBAT_DIR/dash && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
    exit 1
fi
echo "✓ Python venv found"

# ── Free all ports ────────────────────────────────────────────────────
for port in 8050 9100 9101 8060 9200 9201; do
    pids=$(ss -tlnp | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | sort -u || true)
    if [ -n "$pids" ]; then
        echo "Killing processes on port $port: $pids"
        for pid in $pids; do
            kill "$pid" 2>/dev/null || true
        done
    fi
done
sleep 1
echo "✓ All ports free"

# ── Cleanup ───────────────────────────────────────────────────────────
ACROBAT_JULIA_PID=""
ACROBAT_DASH_PID=""
SYSID_JULIA_PID=""
SYSID_DASH_PID=""

cleanup() {
    echo ""
    echo "Shutting down all processes..."
    for pid in $SYSID_DASH_PID $SYSID_JULIA_PID $ACROBAT_DASH_PID $ACROBAT_JULIA_PID; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    for pid in $SYSID_DASH_PID $SYSID_JULIA_PID $ACROBAT_DASH_PID $ACROBAT_JULIA_PID; do
        [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
    echo "Done."
}
trap cleanup EXIT INT TERM

# ══════════════════════════════════════════════════════════════════════
# 1. Start AcrobotSim (plant)
# ══════════════════════════════════════════════════════════════════════
echo ""
echo "── Starting AcrobotSim (plant simulator) ──"
cd "$ACROBAT_DIR"
julia --threads=auto --project=. src/runscript.jl &
ACROBAT_JULIA_PID=$!
echo "  AcrobotSim Julia PID: $ACROBAT_JULIA_PID"

# Wait for AcrobotSim TcpMonitor on port 9100
echo "  Waiting for AcrobotSim TcpMonitor (port 9100)..."
for i in $(seq 1 60); do
    if ss -tln | grep -q ':9100 '; then
        echo "  ✓ AcrobotSim TcpMonitor ready"
        break
    fi
    if ! kill -0 "$ACROBAT_JULIA_PID" 2>/dev/null; then
        echo "  ERROR: AcrobotSim Julia exited unexpectedly"
        exit 1
    fi
    sleep 1
done
if ! ss -tln | grep -q ':9100 '; then
    echo "  ERROR: AcrobotSim TcpMonitor did not start within 60s"
    exit 1
fi

# Start AcrobotSim Dash UI
source "$VENV/bin/activate"
python "$ACROBAT_DIR/dash/app.py" &
ACROBAT_DASH_PID=$!
echo "  AcrobotSim Dash PID: $ACROBAT_DASH_PID (http://localhost:8050)"

# ══════════════════════════════════════════════════════════════════════
# 2. Start SysId (experiment)
# ══════════════════════════════════════════════════════════════════════
echo ""
echo "── Starting SysId (system identification) ──"
cd "$SYSID_DIR"
julia --threads=auto --project=. examples/acrobot_sysid.jl &
SYSID_JULIA_PID=$!
echo "  SysId Julia PID: $SYSID_JULIA_PID"

# Wait for SysId TcpMonitor on port 9200
echo "  Waiting for SysId TcpMonitor (port 9200)..."
for i in $(seq 1 60); do
    if ss -tln | grep -q ':9200 '; then
        echo "  ✓ SysId TcpMonitor ready"
        break
    fi
    if ! kill -0 "$SYSID_JULIA_PID" 2>/dev/null; then
        echo "  ERROR: SysId Julia exited unexpectedly"
        exit 1
    fi
    sleep 1
done
if ! ss -tln | grep -q ':9200 '; then
    echo "  ERROR: SysId TcpMonitor did not start within 60s"
    exit 1
fi

# Start SysId Dash UI
python "$SYSID_DIR/dash/app.py" &
SYSID_DASH_PID=$!
echo "  SysId Dash PID: $SYSID_DASH_PID (http://localhost:8060)"

# ══════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  AcrobotSim + SysId running"
echo ""
echo "  AcrobotSim Dash:  http://localhost:8050"
echo "  SysId Dash:       http://localhost:8060"
echo ""
echo "  AcrobotSim Julia PID: $ACROBAT_JULIA_PID"
echo "  AcrobotSim Dash  PID: $ACROBAT_DASH_PID"
echo "  SysId Julia      PID: $SYSID_JULIA_PID"
echo "  SysId Dash       PID: $SYSID_DASH_PID"
echo "═══════════════════════════════════════════════════════"
echo "  Press Ctrl+C to stop all processes"
echo ""

# Both processes run indefinitely (controlled from Dash). Wait for either to exit.
wait -n "$ACROBAT_JULIA_PID" "$SYSID_JULIA_PID" 2>/dev/null || true
