#!/usr/bin/env python3
"""TCP shaper between the harness client and Beacon: bandwidth cap and one-way delay per direction.

  shaper.py --listen 7980 --target 7979 --down-mbps 8 --up-mbps 8 --delay-ms 5

"down" is host→client (video), "up" is client→host (input, control). Each direction is a token
bucket refilled at the cap, paying per byte, plus a fixed delay applied to every chunk. Good
enough to show queueing and stale-frame behaviour; not a Wi-Fi model.
"""
import asyncio, argparse, time

T0 = time.monotonic()

async def pump(reader, writer, mbps, delay, name, step_at=0, step_mbps=0):
    rate = mbps * 1e6 / 8.0  # bytes per second
    tokens = 0.0; last = time.monotonic()
    burst = max(4096, rate * 0.02)  # 20 ms of burst allowance
    stepped = False
    try:
        while True:
            chunk = await reader.read(16384)
            if not chunk: break
            if step_at and not stepped and name == "down" and time.monotonic() - T0 >= step_at:
                # a bandwidth drop mid-run: Wi-Fi contention arriving, in one step
                rate = step_mbps * 1e6 / 8.0; burst = max(4096, rate * 0.02); stepped = True
                print(f"step: down {mbps} -> {step_mbps} Mbps at {time.monotonic() - T0:.1f}s", flush=True)
            # token bucket
            now = time.monotonic(); tokens = min(burst, tokens + (now - last) * rate); last = now
            need = len(chunk) - tokens
            if need > 0:
                await asyncio.sleep(need / rate)
                now2 = time.monotonic(); tokens = min(burst, tokens + (now2 - last) * rate); last = now2
            tokens -= len(chunk)
            if delay > 0:
                asyncio.get_event_loop().call_later(delay, _write, writer, chunk)
            else:
                writer.write(chunk)
                await writer.drain()
    except (ConnectionResetError, asyncio.CancelledError, BrokenPipeError):
        pass
    finally:
        try:
            if delay > 0: await asyncio.sleep(delay + 0.05)
            writer.close()
        except Exception: pass

def _write(writer, chunk):
    try: writer.write(chunk)
    except Exception: pass

async def handle(client_r, client_w, args):
    server_r, server_w = await asyncio.open_connection("127.0.0.1", args.target)
    server_w.transport.set_write_buffer_limits(low=0, high=64 * 1024)
    client_w.transport.set_write_buffer_limits(low=0, high=64 * 1024)
    await asyncio.gather(
        pump(client_r, server_w, args.up_mbps, args.delay_ms / 1000, "up"),
        pump(server_r, client_w, args.down_mbps, args.delay_ms / 1000, "down", args.step_at, args.step_mbps),
    )

async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, default=7980); ap.add_argument("--target", type=int, default=7979)
    ap.add_argument("--down-mbps", type=float, default=1000); ap.add_argument("--up-mbps", type=float, default=1000)
    ap.add_argument("--delay-ms", type=float, default=0)
    ap.add_argument("--step-at", type=float, default=0, help="seconds after start to drop the down rate")
    ap.add_argument("--step-mbps", type=float, default=0)
    args = ap.parse_args()
    server = await asyncio.start_server(lambda r, w: handle(r, w, args), "127.0.0.1", args.listen)
    async with server: await server.serve_forever()

asyncio.run(main())
