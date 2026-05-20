import csv
import os
import socket
import struct
import threading
from datetime import datetime

from flask import Flask, jsonify, render_template, request
from flask_socketio import SocketIO

from pipeline import Pipeline

app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='threading')

PACKET_FMT  = '<I' + 'h' * 12   # uint32 timestamp + 12 × int16
UDP_PORT    = 4210
LOG_DIR     = os.path.join(os.path.dirname(__file__), 'sessions')
RAW_CSV     = os.path.join(os.path.dirname(__file__), 'results.csv')

RAW_HEADERS = ['ts', 'ax0', 'ay0', 'az0', 'gx0', 'gy0', 'gz0',
               'ax1', 'ay1', 'az1', 'gx1', 'gy1', 'gz1']

# Open results.csv once — append mode, write header only if file is new
_raw_is_new   = not os.path.exists(RAW_CSV) or os.path.getsize(RAW_CSV) == 0
_raw_fh       = open(RAW_CSV, 'a', newline='')
_raw_writer   = csv.writer(_raw_fh)
if _raw_is_new:
    _raw_writer.writerow(RAW_HEADERS)

pipeline = Pipeline(sample_rate=100)

_first_ts_ms = None   # ts_ms of first packet ever received → global t=0

# ── Session state ──────────────────────────────────────────────────────────

session = {
    'active':     False,
    'csv_file':   None,
    'csv_writer': None,
    'stride_num': 0,
    'started_at': None,
}


def _open_session():
    os.makedirs(LOG_DIR, exist_ok=True)
    ts  = datetime.now().strftime('%Y%m%d_%H%M%S')
    path = os.path.join(LOG_DIR, f'session_{ts}.csv')
    f   = open(path, 'w', newline='')
    w   = csv.writer(f)
    w.writerow(['stride', 'time_s', 'omega_pico_degs', 'tau_st_pct', 'alpha_atq_deg'])
    session['csv_file']   = f
    session['csv_writer'] = w
    session['stride_num'] = 0
    session['started_at'] = datetime.now().isoformat()
    print(f'[LOG] Session → {path}')


def _close_session():
    if session['csv_file']:
        session['csv_file'].close()
        session['csv_file']   = None
        session['csv_writer'] = None


# ── REST endpoints ─────────────────────────────────────────────────────────

@app.route('/')
def index():
    return render_template('dashboard.html')


@app.route('/api/session/start', methods=['POST'])
def session_start():
    if not session['active']:
        _open_session()
        session['active'] = True
    return jsonify({'status': 'started', 'at': session['started_at']})


@app.route('/api/session/stop', methods=['POST'])
def session_stop():
    if session['active']:
        _close_session()
        session['active'] = False
    return jsonify({'status': 'stopped'})


@app.route('/api/session/status')
def session_status():
    return jsonify({
        'active':     session['active'],
        'strides':    session['stride_num'],
        'started_at': session['started_at'],
    })


# ── UDP listener ───────────────────────────────────────────────────────────

def udp_listen():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind(('0.0.0.0', UDP_PORT))
    print(f'[UDP] Listening on port {UDP_PORT}')

    expected = struct.calcsize(PACKET_FMT)

    while True:
        try:
            data, addr = sock.recvfrom(1024)
            #print(f'[UDP] recv {len(data)}B from {addr}')
        except Exception as e:
            print(f'[UDP] recv error: {e}')
            continue
        if len(data) < expected:
            print(f'[UDP] bad packet: got {len(data)}B expected {expected}B')
            continue

        ts_ms, ax0, ay0, az0, gx0, gy0, gz0, \
              ax1, ay1, az1, gx1, gy1, gz1 = struct.unpack(PACKET_FMT, data)

        # Normalize timestamp: first packet ever = t=0
        global _first_ts_ms
        if _first_ts_ms is None:
            _first_ts_ms = ts_ms
        norm_ts_ms = ts_ms - _first_ts_ms

        _raw_writer.writerow([norm_ts_ms, ax0, ay0, az0, gx0, gy0, gz0,
                              ax1, ay1, az1, gx1, gy1, gz1])
        _raw_fh.flush()

        #print(f'[PKT] ts={norm_ts_ms} ax0={ax0} ay0={ay0} az0={az0}')
        result = pipeline.process(
            norm_ts_ms / 1000.0,
            ax0, ay0, az0, gx0, gy0, gz0,
            ax1, ay1, az1, gx1, gy1, gz1,
        )

        if result.get('type') == 'live' and result.get('stride') and session['active']:
            s = result['stride']
            session['stride_num'] += 1
            elapsed = round(norm_ts_ms / 1000.0, 3)
            session['csv_writer'].writerow([
                session['stride_num'],
                elapsed,
                s['omega_pico'], s['tau_st_pct'], s['alpha_atq'],
            ])
            session['csv_file'].flush()
            result['stride']['stride_num'] = session['stride_num']
            result['stride']['elapsed']    = elapsed

        socketio.emit('update', result)


# ── Entry point ────────────────────────────────────────────────────────────

if __name__ == '__main__':
    threading.Thread(target=udp_listen, daemon=True).start()
    socketio.run(app, host='0.0.0.0', port=5000, debug=False, use_reloader=False)
