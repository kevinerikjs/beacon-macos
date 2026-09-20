#!/usr/bin/env python3
"""TCP shaper between the harness client and Beacon: bandwidth cap and one-way delay per direction.

  shaper.py --listen 7980 --target 7979 --down-mbps 8 --up-mbps 8 --delay-ms 5 [--step-at 20 --step-mbps 3]

"down" is host→client (video), "up" is client→host (input, control). Each direction is a token
bucket refilled at the cap, paying per byte, plus a fixed delay on every chunk. Kernel socket
buffers on both legs are kept small on purpose: with the default 4 MB loopback window every
byte Beacon sends is acknowledged at once and sits in this process, invisible to the sender's
unacked count and to its pings. A Wi-Fi link queues in the sender's socket buffer and the
access point, which is what the sender can see, so the queue has to be pushed back to it.
Plain blocking sockets and threads: asyncio's stream buffers hid the queue too.
"""
import argparse, socket, threading, time, queue

T0 = time.monotonic()

def pump(src, dst, mbps, delay, name, step_at=0, step_mbps=0, chunk=4096):
    """Reader thread: paces reads with the token bucket, hands each chunk to a sender thread
    that writes it `delay` later. The sender blocks in sendall, so the small socket buffers
    push the queue back to the source."""
    rate = mbps * 1e6 / 8.0
    burst = max(chunk, rate * 0.01)  # 10 ms of burst allowance
    tokens = 0.0; last = time.monotonic(); stepped = False
    q = queue.Queue()
    def sender():
        while True:
            item = q.get()
            if item is None: break
            due, data = item
            wait = due - time.monotonic()
            if wait > 0: time.sleep(wait)
            try: dst.sendall(data)
            except OSError: break
        try: dst.shutdown(socket.SHUT_WR)
        except OSError: pass
    st = threading.Thread(target=sender, daemon=True); st.start()
    try:
        while True:
            if step_at and not stepped and name == "down" and time.monotonic() - T0 >= step_at:
                rate = step_mbps * 1e6 / 8.0; burst = max(chunk, rate * 0.01); stepped = True
                print(f"step: down {mbps} -> {step_mbps} Mbps at {time.monotonic() - T0:.1f}s", flush=True)
            data = src.recv(chunk)
            if not data: break
            now = time.monotonic(); tokens = min(burst, tokens + (now - last) * rate); last = now
            need = len(data) - tokens
            if need > 0:
                time.sleep(need / rate)
                now = time.monotonic(); tokens = min(burst, tokens + (now - last) * rate); last = now
            tokens -= len(data)
            q.put((time.monotonic() + delay, data))
    except OSError:
        pass
    finally:
        q.put(None); st.join()

def small(sock, size):
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    for attempt in range(5):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, size)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, size)
        time.sleep(0.02)
        got = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
        if got <= size: return
        print(f"rcvbuf set {size} read back {got}, attempt {attempt}", flush=True)

def handle(client, args):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.connect(("127.0.0.1", args.target))
    # After connect: macOS autotunes the buffers during the handshake and a size set before
    # it is replaced. Set afterwards it sticks.
    small(server, args.buffer); small(client, args.buffer)
    print(f"buffers rcv={server.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)} snd={client.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)}", flush=True)
    d = args.delay_ms / 1000
    threads = [
        threading.Thread(target=pump, args=(client, server, args.up_mbps, d, "up"), daemon=True),
        threading.Thread(target=pump, args=(server, client, args.down_mbps, d, "down", args.step_at, args.step_mbps), daemon=True),
    ]
    for t in threads: t.start()
    for t in threads: t.join()
    for s in (client, server):
        try: s.close()
        except OSError: pass

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, default=7980); ap.add_argument("--target", type=int, default=7979)
    ap.add_argument("--down-mbps", type=float, default=1000); ap.add_argument("--up-mbps", type=float, default=1000)
    ap.add_argument("--delay-ms", type=float, default=0)
    ap.add_argument("--step-at", type=float, default=0, help="seconds after start to drop the down rate")
    ap.add_argument("--step-mbps", type=float, default=0)
    ap.add_argument("--buffer", type=int, default=16 * 1024, help="kernel socket buffer bytes per leg")
    args = ap.parse_args()
    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", args.listen)); ls.listen(4)
    while True:
        client, _ = ls.accept()
        threading.Thread(target=handle, args=(client, args), daemon=True).start()

main()
